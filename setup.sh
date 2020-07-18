#!/bin/bash
OPNS_VER=20.1				# OPNSense Version
LAN_PORT=eth0				# Physical interface for the LAN
LAN_CIDR=10.2.0.0/16			# CIDR for the LAN
WAN_PORTS=eth1,eth2,eth3		# Comma delimited list of physical interfaces used for WAN failover
WWAN_USB=10a9:6064			# Comma delimited list of (Cellular) USB Ethernet Device IDs
ZT_ID=""				# Zerotier Network ID

# Convert WAN_PORTS to array
if [[ "$WAN_PORTS" == *","* ]]; then 
	IFS=',' read -r -a WAN_PORTS <<< "$WAN_PORTS"
else
	WAN_PORTS=($WAN_PORTS)
fi
# Convert WWAN_USB to array
if [[ "$WWAN_USB" == *","* ]]; then 
	IFS=',' read -r -a WWAN_USB <<< "$WWAN_USB"
else
	WWAN_USB=($WWAN_USB)
fi

clear_network() {
	ip a flush dev $LAN_PORT
	for i in "${WAN_PORTS[@]}"; do
		echo "	Flushing $i IP addresses..."
		ip a flush dev $i
	done
	routes=($(ip r | awk '{print $1}'))
	for i in "${routes[@]}"; do
		echo "	Deleting route $i..."
		ip r d $i
	done
	ip r flush cache
	service networking restart
}

# If something fails, undo the networking and VM changes
revert() {
	echo "Reverting changes as best we can... "
	int_bak=($(find /etc/network/ -name interfaces.*.bak))
	if [ -f ${int_bak[-1]} ]; then cp ${int_bak[-1]} /etc/network/interfaces; rm ${int_bak[-1]}; fi
	VM_ID=$(qm list | grep OPNsense | awk '{print $1}')
	if [ ! -z "$VM_ID" ]; then
		qm stop $VM_ID
		qm destroy $VM_ID
		clear_network
	else
		while true; do
			read -p "Would you like to reset the network configuration? [y/n] " yn
			case $yn in
				[Yy]* ) 
					clear_network
					break;;
				[Nn]* ) 
					echo
					break;;
				* ) echo "Please answer yes or no.";;
			esac
		done
	fi
						
	echo "Done."
	exit
}

# Ask if user wants to revert changes
ask_revert() {
	echo "Signal Interupt detected."
	while true; do
		read -p "Would you like to revert the changes made? [y/n] " yn
		case $yn in
			[Yy]* ) revert; break;;
			[Nn]* ) exit;;
			* ) echo "Please answer yes or no.";;
		esac
	done
}

if [ "$1" = "revert" ]; then revert; fi

# Revert system if script is cancelled or aborted
trap ask_revert SIGINT
trap revert SIGABRT


# Check if a command exists
command_exists() {
	command -v "$@" > /dev/null 2>&1
}

# xq wrapper for "inplace" updates
xml_update() {
	xq -x "$1" $2 > $2.tmp && mv $2.tmp $2
}

# Shift IP address 
ip_shift() {
	# Validate arguments
	if [ -z "$2" ]; then usage; fi
	if [ -z "$(echo $1 | awk -F. '{print $4}')" ]; then usage; fi
	for num in $(echo $1 | awk -F. '{print $1" "$2" "$3" "$4}'); do
		if [ $num -gt 255 ]; then usage; fi
	done

	# Process
	IPNUM=""
	for i in $(echo $1 | awk -F. '{print $1" "$2" "$3" "$4}'); do
		IPNUM="$IPNUM""$(printf "%08d\n" $(echo "obase=2;$i" | bc))"
	done
	IPNUM=$(echo "ibase=2;obase=A;$IPNUM" | bc)

	IPNUM=$(($IPNUM + $2))

	IPNUM=$(echo "obase=2;$IPNUM" | bc)
	if [ $(echo -n $IPNUM | wc -m) -gt 32 ]; then
		IPNUM=$(echo $IPNUM | grep -o "^.\{$(($(echo -n $IPNUM | wc -m) - 32))\}")
	fi
	if [ $(echo -n $IPNUM | wc -m) -lt 32 ]; then
		for i in $(seq 1 $((32 - $(echo -n $IPNUM | wc -m)))); do
			IPNUM=0$IPNUM
		done
	fi
	return=""
	for i in $(echo $IPNUM | sed 's/.\{8\}/& /g'); do
		return=$return" "$(echo "ibase=2;obase=A;$i" | bc)
	done
	echo $return | awk '{print $1"."$2"."$3"."$4}'
}

backup_networking() {
	# Backup /etc/network/interfaces
	if [ ! -d /etc/pve/local/opnsense ]; then mkdir /etc/pve/local/opnsense; fi
	iface_bak=/etc/network/interfaces.$(date +%s).bak
	echo "Backing up /etc/network/interfaces to $iface_bak"
	cp /etc/network/interfaces $iface_bak
}

init_temp_internet() {
	# Check to see if the Internet is already accessible
	if ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; then
		echo "The Internet is already accessible."
		echo "WARNING: The /etc/network/interfaces file will be reconfigured."
		read -t 10 -p "You have 10 seconds to press Ctrl+C to cancel this install." ;
		echo ""
	else
		# Remove the default gateway
		ip r d default
		# Cycle through WAN ports to find working DHCP and Internet connection
		for iface in ${WAN_PORTS[@]}; do
			echo "Attempting to use $iface for temporary Internet access."
			dhclient $iface
			printf "%s" "Waiting for Internet access ..."
			i=0
			while ! ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; do 
				printf "%c" "."
				sleep 1
				((i+=1))
				if [ $i -eq 10 ]; then
					echo ""
					echo "Couldn't connect to the Internet. Is WAN1 plugged in and is there a DHCP?"
					continue
				fi
			done
			break
		done
		echo ""
		if ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; then
			echo "We're online!"
		else
			echo "Couldn't connect to the Internet on any of the defined WAN ports."
			exit 6
		fi
	fi
}

get_prerequisites() {
	# Fix no-subscription repo
	if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
		if [ ! -z "$(pvesubscription get | grep status | grep -v NotFound)" ]; then
			rm /etc/apt/sources.list.d/pve-enterprise.list
			echo deb http://download.proxmox.com/debian/pve buster pve-no-subscription > /etc/apt/sources.list.d/pve-no-subscription.list
		fi
	fi

	# Get updates and required apps
	if ! command_exists expect; then packages="$packages expect"; fi
	if ! command_exists ipcalc; then packages="$packages ipcalc"; fi
	if ! command_exists iptables-save; then packages="$packages iptables-persistent"; fi
	if ! command_exists jq; then packages="$packages jq"; fi
	if ! command_exists pip3; then packages="$packages python3-pip"; fi
	if ! command_exists sshpass; then packages="$packages sshpass"; fi
	if [ -z "$(ifup -V | grep ifupdown2)" ]; then packages="$packages ifupdown2"; fi
	if [ ! -z "$packages" ]; then
		apt-get update
		apt-get upgrade -y
		DEBIAN_FRONTEND=noninteractive apt-get install -y $packages || \
		{
			echo "Couldn't download required packages with apt-get."
			exit 6
		}
	fi
	if [ -z "$(which xq)" ]; then
		pip3 install yq || \
		{
			echo "Couldn't download required packages with pip3."
			exit 6
		}
	fi
	if ! command_exists zerotier-cli; then
		curl -s https://install.zerotier.com | bash
	fi

	# Get OPNSense nano image, convert, and resize it
	if [ ! -f OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 ]; then 
		echo "Downloading OPNsense $OPNS_VER nano image..."
		wget --progress=bar:force http://mirror.wdc1.us.leaseweb.net/opnsense/releases/$OPNS_VER/OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2 2>/dev/null
		if [ ! -f OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2 ]; then
			echo "Couldn't download OPNSense for some reason."
			echo "Does the DHCP on WAN1 provide a working DNS?"
			exit 6
		fi
		echo "Unpacking OPNsense image..."
		bzip2 -d OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2
		echo "Converting RAW image to QCOW2 image..."
		qemu-img convert -p -f raw -O qcow2 OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2
		rm OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img
		echo "Resizing QCOW2 image..."
		qemu-img resize OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 8G
	fi
}

init_zerotier() {
	# Join (stage) Zerotier Network
	if [ -z "$(zerotier-cli listnetworks | grep $ZT_ID)" ]; then
		zerotier-cli join $ZT_ID
	fi
	if [ ! -z "$(zerotier-cli listnetworks | grep $ZT_ID | grep ACCESS_DENIED)" ]; then
		echo "------------------------------------------------------------------------------------------------------"
		echo "Access to the Zerotier network is currently denied."
		echo "Enable device $(zerotier-cli info | awk '{print $3}') at https://my.zerotier.com/network/$ZT_ID"
		echo "This script will wait indefinitely until this device has been approved to access the Zerotier network."
		echo "Press Ctrl+C to cancel."
		echo "------------------------------------------------------------------------------------------------------"
		i=0
		while [ ! -z "$(zerotier-cli listnetworks | grep $ZT_ID | grep ACCESS_DENIED)" ]; do
			((i+=1))
			sleep 1
			if ! (( $i % 5 )) ; then printf "%c" "."; fi
		done
		echo ""
	fi
	while [ "$(zerotier-cli listnetworks | grep $ZT_ID | awk '{print $8}')" = "-" ]; do sleep 1; done
	ZT_IFACE=$(zerotier-cli listnetworks | grep $ZT_ID | awk '{print $8}')
	ZT_NAME=$(zerotier-cli listnetworks | grep $ZT_ID | awk '{print $4}')
	echo "We're connected to the $ZT_NAME network!"
}

configure_network() {
	# Rewrite /etc/network/interfaces file
	MASK=$(echo $LAN_CIDR | awk -F/ '{print $2}')
	IPS=$(echo $LAN_CIDR | awk -F/ '{print $1}')/30
	GW=$(ipcalc $IPS | grep HostMin | awk '{print $2}')
	PVE=$(ipcalc $IPS | grep HostMax | awk '{print $2}')

	cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

iface $LAN_PORT inet manual

auto vmbr0
iface vmbr0 inet static
	address $PVE/$MASK
	gateway $GW
	bridge_ports $LAN_PORT
	bridge_stp off
	bridge_fd 0

EOF

	# Setup virtual machine bridges for the WANs
	j=0
	for i in "${WAN_PORTS[@]}"; do
		((j+=1))
		cat >> /etc/network/interfaces <<EOF
iface $i inet manual

auto vmbr$j
iface vmbr$j inet manual
	bridge_ports $i
	bridge_stp off
	bridge_fd 0

EOF
	done
	service networking restart

	# Set OPNSense as gateway and DNS
	ip r d default
	ip r a default via $GW
	echo search $(hostname -d) > /etc/resolv.conf
	echo nameserver $GW >> /etc/resolv.conf
	cp /etc/network/interfaces /etc/pve/local/opnsense/interfaces

	# Restart Zerotier in order to refresh routes
	service zerotier-one restart
}

# Setup SSH keys
prepare_ssh_key() {
	filename="id_rsa"
	path="/root/.ssh"
	if [ ! -f $path/$filename ]; then
		ssh-keygen -t rsa -f "$path/$filename"
	else
		ssh-keygen -f "$path/known_hosts" -R "$GW"
	fi
	if [ ! -f $path/$filename.pub ]; then ssh-keygen -f $path/$filename -P ""; fi
	key=$(echo $(base64 /root/.ssh/id_rsa.pub) | sed 's/\s//g')
}

# Create init disk
bootstrap_opnsense() {
	# Ready a config import disk
	mkdir -p /var/lib/vz/images/$VM_ID
	qemu-img create -f qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-1.qcow2 512M
	modprobe nbd max_part=8
	qemu-nbd --connect=/dev/nbd0 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-1.qcow2
	while [ ! -b /dev/nbd0 ]; do sleep 1; done
	sgdisk /dev/nbd0 -n 1::1048509
	while [ ! -b /dev/nbd0p1 ]; do sleep 1; done
	mkfs.vfat -F32 /dev/nbd0p1
	qemu-nbd --disconnect /dev/nbd0
	
	# Create the VM
	cp OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2
	qm create $VM_ID \
		--name OPNsense \
		--bootdisk virtio0 \
		--cores 4 \
		--cpu host \
		--memory 8192 \
		--onboot 1 \
		--ostype l26 \
		--scsihw virtio-scsi-pci \
		--serial0 socket \
		--virtio0 local:$VM_ID/vm-$VM_ID-disk-0.qcow2 \
		--virtio1 local:$VM_ID/vm-$VM_ID-disk-1.qcow2 \
		--vga none

	# Add LAN interface to VM
	LAN_VMBR=$(ip -j a | jq -r '.[] | select(.ifname == "'$LAN_PORT'") | .master')
	qm set $VM_ID --net0 virtio,bridge=$LAN_VMBR

	# Add WAN interfaces to VM
	j=1
	for i in "${WAN_PORTS[@]}"; do
		vmbr=$(ip -j a | jq -r '.[] | select(.ifname == "'$i'") | .master')
		qm set $VM_ID --net$j virtio,bridge=$vmbr
		((j+=1))
	done
	# Add WWAN USB devices to VM
	j=0
	for i in "${WWAN_USB[@]}"; do
		qm set $VM_ID --usb$j host=$i,usb3=1
		((j+=1))
	done

	# Start VM
	qm start $VM_ID

	# Bootstrap the config
	/usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
expect -exact "login: "
send "$OPN_USER\r"
expect -exact "Password:"
send "\x0F"
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "$OPN_PASS\r"
expect -exact "Enter an option: "
send "5\r"
expect -exact "The system will halt and power off. Do you want to proceed? \[y/N\]: "
send "y\r"
expect -exact "acpi0: Powering system off"
send "\x0F"
EOF
)
}

modify_opnsense() {
	# Mount the bootstrapped disk
	mkdir -p /var/lib/vz/images/$VM_ID/export
	qemu-nbd --connect=/dev/nbd0 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2
	while [ ! -b /dev/nbd0 ]; do sleep 1; done
	mount -t ufs -o ufstype=44bsd /dev/nbd0 /var/lib/vz/images/$VM_ID/export

	# Mount the config import disk
	mkdir -p /var/lib/vz/images/$VM_ID/import
	qemu-nbd --connect=/dev/nbd1 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-1.qcow2
	while [ ! -b /dev/nbd1p1 ]; do sleep 1; done
	mount /dev/nbd1p1 /var/lib/vz/images/$VM_ID/import

	# Copy bootstrapped config to import
	cp -r /var/lib/vz/images/$VM_ID/export/conf /var/lib/vz/images/$VM_ID/import/

	# Unmount and disconnect the bootstrapped disk
	umount /var/lib/vz/images/$VM_ID/export
	qemu-nbd --disconnect /dev/nbd0

	# Modify the bootstrapped config.xml
	config_path=/var/lib/vz/images/$VM_ID/import/conf/config.xml

	# ------------------------------------------------------------------------------- #
	#                     BEGIN OPNSENSE CONFIG.XML MODIFICATIONS                     #
	# ------------------------------------------------------------------------------- #

	# SSH
	xml_update '.opnsense.system.ssh.noauto=1' $config_path
	xml_update '.opnsense.system.ssh.interfaces="lan"' $config_path
	xml_update '.opnsense.system.ssh.enabled="enabled"' $config_path
	xml_update '.opnsense.system.ssh.permitrootlogin=1' $config_path
	xml_update '.opnsense.system.user.authorizedkeys="'$key'"' $config_path
	xml_update '.opnsense.system.user.shell="/bin/tcsh"' $config_path

	# LAN
	xml_update '.opnsense.interfaces.lan={"enable":1,"if":"vtnet0","ipaddr":"'$GW'","subnet":"'$MASK'","blockbogons":1}' $config_path

	# DHCP
	dhcp_mask=$(($MASK+1))
	dhcp_from=$(ip_shift $(ipcalc $GW/$dhcp_mask | grep Broadcast | awk '{print $2}') +2)
	dhcp_to=$(ipcalc $LAN_CIDR | grep HostMax | awk '{print $2}')
	xml_update '.opnsense.dhcpd.lan={"from":"'$dhcp_from'","to":"'$dhcp_to'"}' $config_path

	# Zerotier Gateway
	opnsense_gateway_items='{"interface":"lan","gateway":"'$PVE'","name":"Zerotier","priority":255,"weight":1,"ipprotocol":"inet","monitor_disable":1}'

	# Zerotier Network Variables
	ZT_NETS=($(ip r | grep $ZT_IFACE | grep -v proto | awk '{print $1}'))
	for n in ${ZT_NETS[@]}; do
		uuid=$(cat /proc/sys/kernel/random/uuid)
		opnsense_routes+='{"@uuid":"'$uuid'","network":"'$n'","gateway":"Zerotier","descr":null,"disabled":0},'
	done
	
	# Zerotier Static Routes
	xml_update '.opnsense.staticroutes."@version"="1.0.0"' $config_path
	xml_update '.opnsense.staticroutes.route=['${opnsense_routes%?}']' $config_path

	# Zerotier Network Aliases
	uuid=$(cat /proc/sys/kernel/random/uuid)
	nets=$(IFS="$ZT_NETS"; shift; echo "\r";)
	opnsense_aliases+='{"@uuid":"'$uuid'","enabled":1,"name":"PublicNets","type":"network","proto":{},"counters":0,"updatefreq":{},"content":"'$nets'","description":{}},'

	# WAN
	j=1
	for i in "${WAN_PORTS[@]}"; do
		descr="WAN$j"
		if [ $j = 1 ]; then 
			iface="wan"
			opnsense_wan_members="$iface"
		else
			iface="opt"$(($j-1))
			opnsense_wan_members+="$opnsense_wan_members $iface"
		fi
		xml_update '.opnsense.interfaces.'$iface'={"enable":1,"if":"vtnet'$j'","descr":"'$descr'","ipaddr":"dhcp","blockbogons":1}' $config_path
		opnsense_gateway_items+=',{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP","priority":'$(($j*10))',"weight":1,"ipprotocol":"inet","monitor":"1.0.0.'$j'"}'
		opnsense_gateway_group_item+='"'$descr'_DHCP|'$j'",'
		((j+=1))
	done

	# WWAN (USB)
	k=0
	for i in "${WWAN_USB[@]}"; do
		iface="opt"$(($j-1))
		descr="WWAN"$(($k+1))
		opnsense_wan_members+="$opnsense_wan_members $iface"
		xml_update '.opnsense.interfaces.'$iface'={"enable":1,"if":"ue'$k'","descr":"'$descr'","ipaddr":"dhcp","blockbogons":1}' $config_path
		opnsense_gateway_items+=',{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP","priority":'$(($j*10))',"weight":1,"ipprotocol":"inet","monitor":"1.0.0.'$j'"}'
		opnsense_gateway_group_item+='"'$descr'_DHCP|'$j'",'
		((j+=1))
		((k+=1))
	done

	# Allow Gateway switching
	xml_update '.opnsense.system.gw_switch_default=1' $config_path

	# Gateways
	xml_update '.opnsense.gateways.gateway_item=['$opnsense_gateway_items']' $config_path

	# Failover Gatway Group
	xml_update '.opnsense.gateways.gateway_group={"name":"Failover","trigger":"down"}' $config_path
	xml_update '.opnsense.gateways.gateway_group.item=['${opnsense_gateway_group_item%?}']' $config_path

	# UnboundDNS
	xml_update '.opnsense.unbound.forwarding=1' $config_path
	xml_update '.opnsense.unbound.active_interface="lan"' $config_path

	# ALL_WANS interface group
	xml_update '.opnsense.ifgroups.ifgroupentry={"ifname":"ALL_WANS","descr":{},"members"="'$opnsense_wan_members'"}' $config_path
	xml_update '.opnsense.interfaces.ALL_WANS={"internal_dynamic":1,"enable":1,"if":"ALL_WANS","descr":"All WANs","virtual":1,"type":"group"}' $config_path

	# Aliases
	uuid=$(cat /proc/sys/kernel/random/uuid)
	nets="0.0.0.0/5\r8.0.0.0/7\r11.0.0.0/8\r12.0.0.0/6\r16.0.0.0/4\r32.0.0.0/3\r64.0.0.0/2\r128.0.0.0/3\r160.0.0.0/5\r168.0.0.0/6\r172.0.0.0/12\r172.32.0.0/11\r172.64.0.0/10\r172.128.0.0/9\r173.0.0.0/8\r174.0.0.0/7\r176.0.0.0/4\r192.0.0.0/9\r192.128.0.0/11\r192.160.0.0/13\r192.169.0.0/16\r192.170.0.0/15\r192.172.0.0/14\r192.176.0.0/12\r192.192.0.0/10\r193.0.0.0/8\r194.0.0.0/7\r196.0.0.0/6\r200.0.0.0/5\r208.0.0.0/4"
	opnsense_aliases+='{"@uuid":"'$uuid'","enabled":1,"name":"PublicNets","type":"network","proto":{},"counters":0,"updatefreq":{},"content":"'$nets'","description":{}}'
	xml_update '.opnsense.OPNsense.Firewall.Alias.aliases.alias=['$opnsense_aliases']' $config_path

	# Firewall Rules
	opnsense_firewall_rules+='{"type":"pass","interface":"lan","ipprotocol":"inet","statetype":"keep state","descr":"Use Failover Gateway for Internet Traffic","direction":"in","quick":1,"source":{"network":"lan"},"destination":{"address":"PublicNets"}},'
	opnsense_firewall_rules+='{"type":"pass","interface":"lan","ipprotocol":"inet46","statetype":"keep state","descr":"Default allow LAN to any rule","direction":"in","quick":1,"source":{"network":"lan"},"destination":{"any":1}}'
	xml_update '.opnsense.filter.rule=['$opnsense_firewall_rules']' $config_path

	# ------------------------------------------------------------------------------- #
	#                      END OPNSENSE CONFIG.XML MODIFICATIONS                      #
	# ------------------------------------------------------------------------------- #

	# Unmount and disconnect the config import disk
	umount /var/lib/vz/images/$VM_ID/import
	qemu-nbd --disconnect /dev/nbd1

}

init_opnsense() {
	# Replace boot disk with fresh nano
	cp OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2

	# Start VM, import config, wait for login
	qm start $VM_ID
	/usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
expect -exact "Press any key to start the configuration importer: "
send "\r"
expect -exact "Select device to import from (e.g. ada0) or leave blank to exit: "
send "vtbd1\r"
expect -exact "login: "
send "\x0F"
EOF
)
}

update_opnsense() {
	/usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "$OPN_USER\r"
expect -exact "Password:"
send "\x0F"
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "$OPN_PASS\r"
expect -exact "root@OPNsense:~ #"
send "opnsense-update\r"
expect -exact "root@OPNsense:~ #"
send "reboot\r"
expect -exact "login: "
send "\x0F"
EOF
)
}

configure_iptables() {
	# Enable IPV4 forwarding
	sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/g' /etc/sysctl.conf
	sysctl -w net.ipv4.ip_forward=1

	# Enable Zerotier and LAN forwarding
	rule1=$(iptables -S | grep -e "-A FORWARD -i $LAN_VMBR -o $ZT_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT")
	if [ -z "$rule1" ]; then
		iptables -A FORWARD -i $LAN_VMBR -o $ZT_IFACE -m state --state RELATED,ESTABLISHED -j ACCEPT
	fi
	rule2=$(iptables -S | grep -e "-A FORWARD -i $ZT_IFACE -o $LAN_VMBR -j ACCEPT")
	if [ -z "$rule2" ]; then
		iptables -A FORWARD -i $ZT_IFACE -o $LAN_VMBR -j ACCEPT
	fi
	rule3=$(iptables -t nat -S | grep -e "-A POSTROUTING -o $LAN_VMBR -j MASQUERADE")
	if [ -z "$rule3" ]; then
		iptables -t nat -A POSTROUTING -o $LAN_VMBR -j MASQUERADE
	fi
	iptables-save > /etc/iptables/rules.v4
}

# Bootstrap Host
backup_networking
init_temp_internet
get_prerequisites
init_zerotier
configure_network
prepare_ssh_key
configure_iptables

# Default user/pass
OPN_USER=root
OPN_PASS=opnsense

# Generate root password
if [ ! -f /etc/pve/local/opnsense/.rp ]; then
	echo $(date +%s | sha256sum | base64 | head -c 32 ; echo) > /etc/pve/local/opnsense/.rp
fi
OPNSENSE=$(cat /etc/pve/local/opnsense/.rp)

# Wipe old VM if exists
VM_ID=$(qm list | grep OPNsense)
if [ -z "$VM_ID" ]; then
	VM_ID=$(pvesh get /cluster/nextid)
else
	VM_ID=$(echo $VM_ID | awk '{print $1}')
	qm stop $VM_ID
	qm destroy $VM_ID
fi

# OPNsense Build
bootstrap_opnsense
modify_opnsense
init_opnsense
update_opnsense

# Restart Zerotier for good measure
service zerotier-one restart
