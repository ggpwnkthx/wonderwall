#!/bin/bash
LONG_OPTS=(
    "opnsense-version:"
    "man-vmbr:"
    "man-iface:"
    "man-cidr:"
    "lan-vmbrs:"
    "lan-ifaces:"
    "wan-vmbrs:"
    "wan-ifaces:"
    "usb-ids:"
    "zt-net-id:"
    "zt-lan-cidr:"
    "help"
    "revert"
)

OPTS=$(getopt \
    --longoptions "$(printf "%s," "${LONG_OPTS[@]}")" \
    --name "$(basename "$0")" \
    --options "" \
    -- "$@"
)
eval set -- "$OPTS"

# Default Values
OPNS_VER=20.7
MAN_CIDR=192.168.1.0/24
ZT_LAN_MAP=10.0.0.0/16
if [ -f /etc/pve/local/opnsense/zerotier/networks.d/*.local.conf ]; then
    ZT_ID=$(ls /etc/pve/local/opnsense/zerotier/networks.d/*.local.conf | awk -F/ '{print $NF}' | awk -F. '{print $1}')
fi

while [[ $# -gt 0 ]]; do
    case "$1" in
        --opnsense-version ) OPNS_VER="$2";   shift 2;;
        --man-vmbr )         MAN_VMBR="$2";   shift 2;;
        --man-iface )        MAN_IFACE="$2";  shift 2;;
        --man-cidr )         MAN_CIDR="$2";   shift 2;;
        --lan-vmbrs )        LAN_VMBRS="$2";  shift 2;;
        --lan-ifaces )       LAN_IFACES="$2"; shift 2;;
        --wan-vmbrs )        WAN_VMBRS="$2";  shift 2;;
        --wan-ifaces )       WAN_IFACES="$2"; shift 2;;
        --usb-ids )          USB_IDS="$2";    shift 2;;
        --zt-net-id )        ZT_ID="$2";      shift 2;;
        --zt-lan-cidr )      ZT_LAN_MAP="$2"; shift 2;;
        --revert )           REVERT=1;        shift;;
        --help )             HELP=1;          shift;;
        -- ) shift; break ;;
        * ) break ;;
    esac
done

if [ $HELP ]; then
    cat <<EOF
WONDERWALL INSTALLATION SCRIPT OPTIONS:
    --opnsense-version
        Description: Version of OPNsense to download and use. Updates will be
                        run, so it's rare this would ever need to be set.
        Optional:    Yes
        Default:     20.7
    --man-vmbr
        Description: L3 bridge to use for the Management interface. If no value
                        is given a L3 bridge with no interfaces will be created.
        Example:     vmbr0
    --man-iface
        Description: Physical interface for the management network.
                     If no interface is given a L3 bridge with no interfaces
                        will be created.
        Example:     eno1
        WARNING:     Using this option will replace the current network config.
    --man-cidr
        Description: CIDR used by the Management network.
                     OPNsense will be configured to use the first available IP
                        address. Proxmox will be configured to use the second
                        available IP address.
        Default:     192.168.1.0/24
    --lan-vmbrs
        Description: Comma delimited list of L3 bridges defined by Proxmox. 
                     Each bridge will be configured in OPNsense as an individual
                        interface. Each interface in OPNsense will be
                        configured based on the IP addressed provided by
                        Zerotier, relative to the --zt-lan-cidr value. DHCP 
                        services will be configure for the last half of the 
                        subnet.
        Example:     vmbr1,vmbr2
    --lan-ifaces
        Description: Comma delimited list of physical interfaces used for LANs. 
                     Each interface will have it's own L3 bridge. Each bridge
                        will be configured in OPNsense as an individual
                        interface. Each interface in OPNsense will be
                        configured based on the IP addressed provided by
                        Zerotier, relative to the --zt-lan-cidr value. DHCP 
                        services will be configure for the last half of the 
                        subnet.
        Example:     eno1,eno2,eno3,eno4
        WARNING:     Using this option will replace the current network config.
    --wan-vmbrs
        Description: Comma delimited list of L3 bridges defined by Proxmox.
                     Each bridge will be configured in OPNsense as an individual
                        interface. Each interface in OPNsense DHCP will be used
                        on all interfaces. WAN failover will be automatically 
                        configured in a tier based on the provided order.
        Example:     vmbr3,vmbr4
    --wan-ifaces
        Description: Comma delimited list of physical interfaces used for WANs.
                     Each interface will have it's own L3 bridge. Each bridge
                        will be configured in OPNsense as an individual
                        interface. Each interface in OPNsense DHCP will be used
                        on all interfaces. WAN failover will be automatically 
                        configured in a tier based on the provided order.
        Example:     eno1,eno2,eno3,eno4
        WARNING:     Using this option will replace the current network config.
    --usb-ids
        Description: Comma delimited list of USB Device IDs. 
                     **Must be USB Ethernet devices.
        Example:     10a9:6064
    --zt-net-id
        Description: Zerotier Network ID to join.
        Example:     1234567890abcdef
    --zt-lan-cidr
        Description: Starting CIDR for LANs defined by assigned Zerotier IPs
        Default:     10.0.0.0/16
    --revert
        Description: Revert changes, made by the installer script, back to
                        right before the first time the script was run.
    --help
        Description: Displays this message.
EOF
    exit
fi

console_message() {
    message=$(echo "$@" | fmt -w 76)
    output='
╔══════════════════════════════════════════════════════════════════════════════╗
'
    while IFS= read -r line; do
        output+='║  '"$(printf '%-74s' "$line")"'  ║
'
    done <<< "$message"
    output+='╚══════════════════════════════════════════════════════════════════════════════╝'
    echo "$output" 1>&2
}

clear_network() {
    for i in $(ls /sys/class/net/) ; do
        /usr/sbin/ip addr flush $i &
    done
    routes=($(ip r | awk '{print $1}'))
    for i in "${routes[@]}"; do
        echo "    Deleting route $i..."
        ip r d $i
    done
    ip r flush cache
    service networking restart
}
# If something fails, undo the networking and VM changes
revert() {
    console_message "Reverting changes as best we can... "
    int_bak=($(find /etc/network/ -name interfaces.*.bak))
    if [ -f ${int_bak[0]} ]; then cp ${int_bak[0]} /etc/network/interfaces; fi
    res_bak=($(find /etc/ -name resolve.conf.*.bak))
    if [ -f ${res_bak[0]} ]; then cp ${res_bak[0]} /etc/resolve.conf; fi
    VM_ID=$(qm list | grep OPNsense | awk '{print $1}')
    if [ ! -z "$VM_ID" ]; then
        qm stop $VM_ID
        qm destroy $VM_ID
    fi
    while true; do
        read -p "Delete configs? [y/n] " yn
        case $yn in
            [Yy]* ) 
                if [ -d /etc/pve/local/opnsense ]; then rm -r /etc/pve/local/opnsense; fi
                break;;
            [Nn]* ) break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
    while true; do
        read -p "Delete download cache? [y/n] " yn
        case $yn in
            [Yy]* ) 
                if [ -f OPNsense-*.img.bz2 ]; then rm OPNsense-*.img.bz2; fi
                if [ -f OPNsense-*.img ]; then rm OPNsense-*.img; fi
                if [ -f OPNsense-*.qcow2 ]; then rm OPNsense-*.qcow2; fi
                break;;
            [Nn]* ) break;;
            * ) echo "Please answer yes or no.";;
        esac
    done
    clear_network
    console_message "Done reveting changes."
    exit
}

if [ $REVERT ]; then revert; fi

# Ask if user wants to revert changes
ask_revert() {
    console_message "Signal Interupt detected."
    while true; do
        read -p "Would you like to revert the changes made? [y/n] " yn
        case $yn in
            [Yy]* ) revert; break;;
            [Nn]* ) exit;;
            * ) echo "Please answer yes or no.";;
        esac
    done
}

# Input Validation Checks
## Make sure we have some sort of networks to work with
if [[ -z "$MAN_VMBR" && -z "$LAN_VMBRS" && -z "$WAN_VMBRS" && -z "$MAN_IFACE" && -z "$LAN_IFACES" && -z "$WAN_IFACES" ]]; then
    console_message "ERROR!!! No interfaces of bridges specifed so there's nothing to set up."
    exit 6
fi
## Do not allow VMBR and IFACE combos
vmbr_iface_error="ERROR!!! You cannot use any combination of the --xxx-vmbr(s) and --xxx-iface(s) options. When the --man-iface, --lan-ifaces, and/or --wan-ifaces options are used, the network configuration is completely replaced."
if [[ ! -z "$MAN_VMBR" || ! -z "$LAN_VMBRS" ||  ! -z "$WAN_VMBRS" ]]; then
    if [[ ! -z "$MAN_IFACE" || ! -z "$LAN_IFACES" ||  ! -z "$WAN_IFACES" ]]; then
        console_message $vmbr_iface_error
        exit 6
    fi
fi
## Validate CIDR
validate_cidr() {
    if [[ ! "$1" =~ ^([0-9\.\/]*$) ]]; then return 1; fi
    IFS="./" read -r ip1 ip2 ip3 ip4 N <<< $1
    if [[ -z $ip1 || -z $ip2 || -z $ip3 || -z $ip4 || -z $N ]]; then return 1; fi
    if [[ $ip1 -gt 255 || $ip2 -gt 255 || $ip3 -gt 255 || $ip4 -gt 255 || $N -gt 32 ]]; then return 1; fi
    return 0
}
if ! validate_cidr $MAN_CIDR; then console_message "ERROR!!! --man-cidr \"$MAN_CIDR\" is not valid CIDR notation."; exit 6; fi
if ! validate_cidr $ZT_LAN_MAP; then console_message "ERROR!!! --zt-lan-cidr \"$ZT_LAN_MAP\" is not valid CIDR notation."; exit 6; fi
## Zerotier Network ID
if [[ ! "$ZT_ID" =~ ^([0-9a-fA-F]*$) ]] || [ $(echo $ZT_ID | wc -c) -ne 17 ]; then console_message "ERROR!!! --zt-net-id \"$ZT_ID\" is not a valid Zerotier network ID."; exit 6; fi

# Convert LAN_VMBRS to array
if [[ "$LAN_VMBRS" == *","* ]]; then 
    IFS=',' read -r -a LAN_VMBRS <<< "$LAN_VMBRS"
else
    LAN_VMBRS=($LAN_VMBRS)
fi
# Convert LAN_IFACES to array
if [[ "$LAN_IFACES" == *","* ]]; then 
    IFS=',' read -r -a LAN_IFACES <<< "$LAN_IFACES"
else
    LAN_IFACES=($LAN_IFACES)
fi
# Convert WAN_VMBRS to array
if [[ "$WAN_VMBRS" == *","* ]]; then 
    IFS=',' read -r -a WAN_VMBRS <<< "$WAN_VMBRS"
else
    WAN_VMBRS=($WAN_VMBRS)
fi
# Convert WAN_IFACES to array
if [[ "$WAN_IFACES" == *","* ]]; then 
    IFS=',' read -r -a WAN_IFACES <<< "$WAN_IFACES"
else
    WAN_IFACES=($WAN_IFACES)
fi
# Convert USB_IDS to array
if [[ "$USB_IDS" == *","* ]]; then 
    IFS=',' read -r -a USB_IDS <<< "$USB_IDS"
else
    USB_IDS=($USB_IDS)
fi

# Revert system if script is cancelled or aborted
trap ask_revert SIGINT
trap revert SIGABRT

# Check if a command exists
command_exists() {
    command -v "$@" > /dev/null 2>&1
}

# DNS Ping
ding() {
    if [ -z "$(dig +time=3 +tries=5 @$1 | grep 'connection timed out')" ]; then return 0; else return 1; fi
}

# xq wrapper to get json output of a current value
xml_get() {
    query=$(echo "${@:1:$#-1}" | sed "s/\"/\\\"/g")
    target=${@: -1}
    echo "[$target] $query"
    xq -r "$query" $target
}
# xq wrapper for updates
xml_update() {
    query=$(echo "${@:1:$#-1}" | sed "s/\"/\\\"/g")
    target=${@: -1}
    echo "[$target] $query"
    xq -x "$query" $target > $target.tmp && mv $target.tmp $target
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

terminal_opnsense_nowait() {
    /usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
log_user 0
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "\r"
log_user 1
expect {
    "login: " {
        send "$OPN_USER\r"
        expect "Password:"
        log_user 0
        send "\x0F"
        spawn qm terminal $VM_ID
        expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
        send "$OPN_PASS\r"
        log_user 1
        expect {
            "Enter an option: " {
                send "8\r"
            }
            ":~ #" {
                send "$@\r"
            }
        }
    }
    "Enter an option: " {
        send "8\r"
        expect ":~ #"
        send "$@\r"
    }
    ":~ #" {
        send "$@\r"
    }
}
send "\x0F"
EOF
)
}
terminal_opnsense_wait() {
    /usr/bin/expect <(cat << EOF
log_user 0
set timeout -1
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "\r"
expect ":~ #"
send "\x0F"
EOF
)
}
terminal_opnsense() {
    terminal_opnsense_nowait > /dev/null
    output=$(/usr/bin/expect <(cat << EOF
log_user 0
set timeout -1
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
log_user 1
send "$@\r"
expect ":~ #"
log_user 0
send "\x0F"
EOF
) | sed '1d;2d;$d')
    echo "$output"
}
terminal_opnsense_shell() {
    terminal_opnsense_nowait
    terminal_opnsense_wait
    /usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
expect -exact "starting serial terminal on interface serial0 (press Ctrl+O to exit)"
send "opnsense-shell\r"
expect "Enter an option: "
send "$1\r"
expect "\[y/N\]"
send "y\r"
send "\x0F"
EOF
)
}

ssh_opnsense() {
    ssh -o ConnectTimeout=5 -t $OPNSENSE_MAN_IP "$@"
}

install_opnsense_package() {
    ssh_opnsense pkg install -y $1
}

vm_opnsense_status() {
    qm list | awk '{print $1" "$3}' | grep "^$VM_ID" | awk '{print $2}'
}

backup_networking() {
    # Backup /etc/network/interfaces
    if [ ! -d /etc/pve/local/opnsense ]; then mkdir /etc/pve/local/opnsense; fi
    iface_bak=/etc/network/interfaces.$(date +%s).bak
    console_message "Backing up /etc/network/interfaces to $iface_bak"
    cp /etc/network/interfaces $iface_bak
    res_bak=/etc/resolv.conf.$(date +%s).bak
    console_message "Backing up /etc/resolv.conf to $res_bak"
    cp /etc/resolv.conf $res_bak
}

init_temp_internet() {
    # Check to see if the Internet is already accessible
    if ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; then
        console_message "The Internet is already accessible."
    else
        # Remove the default gateway
        ip r d default
        # Cycle through WAN ports to find working DHCP and Internet connection
        if [ -z "$WAN_IFACES" ]; then WAN_TRY=($WAN_VMBRS); else WAN_TRY=($WAN_IFACES); fi
        for iface in "${WAN_TRY[@]}"; do
            console_message "Attempting to use $iface for temporary Internet access."
            mv /etc/resolv.conf 
            dhclient $iface
            printf "%s" "Waiting for Internet access ..."
            i=0
            while ! ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; do 
                printf "%c" "."
                sleep 1
                ((i+=1))
                if [ $i -eq 10 ]; then
                    console_message "Couldn't connect to the Internet. Is WAN1 plugged in and is there a DHCP?"
                    continue
                fi
            done
            break
        done
        echo ""
        if ping -c 1 -n -w 1 1.1.1.1 &> /dev/null; then
            console_message "We're online!"
        else
            console_message "Couldn't connect to the Internet on any of the defined WAN ports."
            exit 6
        fi
    fi
}

get_prerequisites() {
    console_message "Downloading missing prerequisites..."
    # Fix no-subscription repo
    if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
        if [ ! -z "$(pvesubscription get | grep status | grep -v NotFound)" ]; then
            rm /etc/apt/sources.list.d/pve-enterprise.list
            echo deb http://download.proxmox.com/debian/pve buster pve-no-subscription > /etc/apt/sources.list.d/pve-no-subscription.list
        fi
    fi

    # Get updates and required apps
    if ! command_exists expect; then packages+=" expect"; fi
    if ! command_exists ipcalc; then packages+=" ipcalc"; fi
    if ! command_exists jq; then packages+=" jq"; fi
    if ! command_exists pip3; then packages+=" python3-pip"; fi
    if [ -z "$(ifup -V | grep ifupdown2)" ]; then packages+=" ifupdown2"; fi
    if [ ! -z "$packages" ]; then
        apt-get update
        apt-get upgrade -y
        DEBIAN_FRONTEND=noninteractive apt-get install -y $packages || \
        {
            console_message "Couldn't download required packages with apt-get."
            exit 6
        }
    fi
    if [ -z "$(which xq)" ]; then
        pip3 install yq || \
        {
            console_message "Couldn't download required packages with pip3."
            exit 6
        }
    fi

    # Get OPNSense nano image, convert, and resize it
    if [ ! -f OPNsense-latest-OpenSSL-nano-amd64.qcow2 ]; then
        if [ ! -f OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 ]; then 
            console_message "Downloading OPNsense $OPNS_VER nano image..."
            wget http://mirror.wdc1.us.leaseweb.net/opnsense/releases/$OPNS_VER/OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2
            if [ ! -f OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2 ]; then
                console_message "Couldn't download OPNSense for some reason. Does the DHCP on WAN1 provide a working DNS?"
                exit 6
            fi
            console_message "Unpacking OPNsense image..."
            bzip2 -d OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img.bz2
            console_message "Converting RAW image to QCOW2 image..."
            qemu-img convert -p -f raw -O qcow2 OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2
            rm OPNsense-$OPNS_VER-OpenSSL-nano-amd64.img
            console_message "Resizing QCOW2 image..."
            qemu-img resize OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 8G
        fi
    fi
}

bootstrap_network() {
    if [[ ! -z "$MAN_IFACE" || ! -z "$LAN_IFACES" ||  ! -z "$WAN_IFACES" ]]; then
        console_message "Bootstraping network configuration. Please wait..."
        MAN_NET=$(ipcalc $MAN_CIDR | grep Network | awk '{print $2}')
        MAN_MASK=$(echo $MAN_NET | awk -F/ '{print $2}')
        IPS=$(echo $MAN_NET | awk -F/ '{print $1}')/30
        OPNSENSE_MAN_IP=$(ipcalc $IPS | grep HostMin | awk '{print $2}')
        PVE_MAN_IP=$(ipcalc $IPS | grep HostMax | awk '{print $2}')
        configure_network
    else
        if [ ! -z "$MAN_VMBR" ]; then 
            man_cidr=$(ip -j a | jq -r '.[] | select(.ifname=="'$MAN_VMBR'") | .addr_info[] | select(.family=="inet") | .local + "/" + (.prefixlen|tostring)')
            if validate_cidr $man_cidr; then 
                console_message "Scanning for usable IP address for the OPNsense managment network..."
                PVE_MAN_IP=$(echo "$man_cidr" | awk -F/ '{print $1}')
                MAN_MIN_IP=$(ipcalc $man_cidr | grep HostMin | awk '{print $2}')
                MAX_MIN_IP=$(ipcalc $man_cidr | grep HostMax | awk '{print $2}')
                i=1
                while [ -z "$OPNSENSE_MAN_IP" ]; do
                    echo $i
                    if [ "$next_man_ip" = "MAN_MIN_IP" ]; then
                        console_message "ERROR!!! Cannot find a suitable IP address for the OPNsense management interface."
                        exit 6
                    fi
                    case $i in
                        1) if ! ping -c 1 -n -w 1 $MAN_MIN_IP &> /dev/null; then OPNSENSE_MAN_IP=$MAN_MIN_IP; fi ;;
                        2) if ! ping -c 1 -n -w 1 $MAN_MIN_IP &> /dev/null; then OPNSENSE_MAN_IP=$MAN_MIN_IP; else next_man_ip=$(shift_ip $MAN_MIN_IP +1); fi ;;
                        *) if ! ping -c 1 -n -w 1 $next_man_ip &> /dev/null; then OPNSENSE_MAN_IP=$next_man_ip; else next_man_ip=$(shift_ip $next_man_ip +1); fi ;;
                    esac
                    ((i+=1))
                done
            else
                console_message "ERROR!!! Something went wrong setting up the Management netowrk."
                exit 6
            fi
        else
            vmbrs=($(ip -j a | jq -r 'sort_by((.ifname | explode | map(-.))) | .[] | select(.ifname | startswith("vmbr")) | .ifname'))
            if [ -z "$vmbrs" ]; then next_vmbr=vmbr0; else next_vmbr="vmbr$((${vmbrs[0]:4}+1))"; fi
            MAN_NET=$(ipcalc $MAN_CIDR | grep Network | awk '{print $2}')
            MAN_MASK=$(echo $MAN_NET | awk -F/ '{print $2}')
            IPS=$(echo $MAN_NET | awk -F/ '{print $1}')/30
            OPNSENSE_MAN_IP=$(ipcalc $IPS | grep HostMin | awk '{print $2}')
            PVE_MAN_IP=$(ipcalc $IPS | grep HostMax | awk '{print $2}')
            cat >> /etc/network/interfaces <<EOF
auto $next_vmbr
iface $next_vmbr inet manual
    address $PVE_MAN_IP/$MAN_MASK
    gateway $OPNSENSE_MAN_IP
    bridge_stp off
    bridge_fd 0

EOF
        fi
    fi
    service networking restart

    # Set OPNSense as gateway and DNS
    ip r d default
    ip r a default via $OPNSENSE_MAN_IP
    echo nameserver $OPNSENSE_MAN_IP > /etc/resolv.conf
    cp /etc/network/interfaces /etc/pve/local/opnsense/interfaces
}

configure_network() {
    # Rewrite /etc/network/interfaces file
    cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

EOF

    # Setup bridge for the management port
    j=0
if [ ! -z "$MAN_IFACE" ]; then
    MAN_VMBR=vmbr$j
    cat >> /etc/network/interfaces <<EOF
iface $MAN_IFACE inet manual

EOF
fi
    cat >> /etc/network/interfaces <<EOF
auto vmbr$j
iface vmbr$j inet static
    address $PVE_MAN_IP/$MAN_MASK
    gateway $OPNSENSE_MAN_IP
EOF
    if [ -z "$MAN_IFACE" ]; then
        echo "    bridge_ports none" >> /etc/network/interfaces
    else
        echo "    bridge_ports $MAN_IFACE" >> /etc/network/interfaces
    fi
    cat >> /etc/network/interfaces <<EOF
    bridge_stp off
    bridge_fd 0

EOF

    # Setup bridges for the LANs
    for i in "${LAN_IFACES[@]}"; do
        ((j+=1))
        LAN_VMBRS+=(vmbr$j)
        cat >> /etc/network/interfaces <<EOF
iface $i inet manual

auto vmbr$j
iface vmbr$j inet static
    bridge_ports $i
    bridge_stp off
    bridge_fd 0

EOF
    done

    # Setup bridges for the WANs
    for i in "${WAN_IFACES[@]}"; do
        ((j+=1))
        WAN_VMBRS+=(vmbr$j)
        cat >> /etc/network/interfaces <<EOF
iface $i inet manual

auto vmbr$j
iface vmbr$j inet manual
    bridge_ports $i
    bridge_stp off
    bridge_fd 0

EOF
    done
}

# Setup SSH keys
prepare_ssh_key() {
    console_message "Configuring SSH keys..."
    filename="id_rsa"
    path="/root/.ssh"
    if [ ! -f $path/$filename ]; then
        ssh-keygen -t rsa -f "$path/$filename"
    else
        ssh-keygen -f "$path/known_hosts" -R "$OPNSENSE_MAN_IP"
    fi
    if [ ! -f $path/$filename.pub ]; then ssh-keygen -f $path/$filename -P ""; fi
    console_message "Done configuring SSH keys."
}

set_opnsense_base_config() {
    # Modify the bootstrapped config.xml
    config_path=$1

    console_message "Modifying the OPNsense config file: $config_path"
    # ------------------------------------------------------------------------------- #
    #                     BEGIN OPNSENSE CONFIG.XML MODIFICATIONS                     #
    # ------------------------------------------------------------------------------- #

    # SSH
    xml_update '.opnsense.system.ssh.noauto=1' $config_path
    xml_update '.opnsense.system.ssh.interfaces="lan"' $config_path
    xml_update '.opnsense.system.ssh.enabled="enabled"' $config_path
    xml_update '.opnsense.system.ssh.permitrootlogin=1' $config_path
    xml_update '.opnsense.system.user.authorizedkeys="'$(echo $(base64 /root/.ssh/id_rsa.pub) | sed 's/\s//g')'"' $config_path
    xml_update '.opnsense.system.user.shell="/bin/tcsh"' $config_path

    # WebGUI
    xml_update '.opnsense.system.webgui.port=8443' $config_path
    xml_update '.opnsense.system.webgui.disablehttpredirect=1' $config_path

    # Interfaces
    ## Management (OPNsense requires in interface specifically named lan)
    xml_update '.opnsense.interfaces.lan={"enable":1,"if":"vtnet0","descr":"Management","ipaddr":"'$OPNSENSE_MAN_IP'","subnet":"'$MAN_MASK'","blockbogons":1}' $config_path
    opnsense_filter_rules+='{"type":"pass","interface":"lan","ipprotocol":"inet46","statetype":"keep state","descr":"Default Allow","direction":"in","quick":1,"source":{"any":1},"destination":{"any":1}},'
    
    vtnet_id=1
    ## LAN
    lan_id=1
    for i in "${LAN_VMBRS[@]}"; do
        iface="lan$lan_id"
        descr="LAN$lan_id"
        xml_update '.opnsense.interfaces.'$iface'={"enable":1,"if":"vtnet'$vtnet_id'","descr":"'$descr'"}' $config_path
        lan_group+="$iface "
        ((lan_id+=1))
        ((vtnet_id+=1))
    done
    ## WAN
    wan_id=1
    xml_update 'del(.opnsense.interfaces.wan)' $config_path
    for i in "${WAN_VMBRS[@]}"; do
        iface="wan$wan_id"
        descr="WAN$wan_id"
        xml_update '.opnsense.interfaces.'$iface'={"enable":1,"if":"vtnet'$vtnet_id'","descr":"'$descr'","ipaddr":"dhcp","ipaddrv6":"dhcp6","blockbogons":1}' $config_path
        opnsense_gateway_items+='{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP","priority":'$(($wan_id*10+100))',"weight":1,"ipprotocol":"inet","monitor":"1.0.0.'$j'"},'
        opnsense_gateway_groupv4_item+='"'$descr'_DHCP|'$wan_id'",'
        opnsense_gateway_items+='{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP6","priority":'$(($wan_id*10+105))',"weight":1,"ipprotocol":"inet6","monitor":"2606:4700:4700::100'$j'"},'
        opnsense_gateway_groupv6_item+='"'$descr'_DHCP6|'$wan_id'",'
        wan_group+="$iface "
        ((wan_id+=1))
        ((vtnet_id+=1))
    done
    ## WWAN (USB)
    usb_id=1
    for i in "${USB_IDS[@]}"; do
        iface="wwan$usb_id"
        descr="WWAN$usb_id"
        xml_update '.opnsense.interfaces.'$iface'={"enable":1,"if":"ue'$(($usb_id-1))'","descr":"'$descr'","ipaddr":"dhcp","ipaddrv6":"dhcp6","blockbogons":1}' $config_path
        opnsense_gateway_items+='{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP","priority":'$(($wan_id*10+100))',"weight":1,"ipprotocol":"inet","monitor":"1.0.0.'$j'"},'
        opnsense_gateway_groupv4_item+='"'$descr'_DHCP|'$wan_id'",'
        opnsense_gateway_items+='{"interface":"'$iface'","gateway":"dynamic","name":"'$descr'_DHCP6","priority":'$(($wan_id*10+105))',"weight":1,"ipprotocol":"inet6","monitor":"2606:4700:4700::100'$j'"},'
        opnsense_gateway_groupv6_item+='"'$descr'_DHCP6|'$wan_id'",'
        wan_group+="$iface "
        ((usb_id+=1))
        ((wan_id+=1))
    done
    ## Groups
    xml_update '.opnsense.ifgroups.ifgroupentry=[{"ifname":"LANs","members":"'${lan_group%?}'"},{"ifname":"WANs","members":"'${wan_group%?}'"}]' $config_path
    xml_update '.opnsense.interfaces.LANs={"internal_dynamic":1,"enable":1,"if":"LANs","descr":"LANs","virtual":1,"type":"group"}' $config_path
    xml_update '.opnsense.interfaces.WANs={"internal_dynamic":1,"enable":1,"if":"WANs","descr":"WANs","virtual":1,"type":"group"}' $config_path

    # Allow Gateway switching
    xml_update '.opnsense.system.gw_switch_default=1' $config_path

    # Gateways
    xml_update '.opnsense.gateways.gateway_item=['${opnsense_gateway_items%?}']' $config_path

    # Failover Gatway Group
    opnsense_gateway_groups+='{"name":"Failover_v4","trigger":"down","item":['${opnsense_gateway_groupv4_item%?}']},'
    opnsense_gateway_groups+='{"name":"Failover_v6","trigger":"down","item":['${opnsense_gateway_groupv6_item%?}']}'
    xml_update '.opnsense.gateways.gateway_group=['$opnsense_gateway_groups']' $config_path

    # UnboundDNS
    xml_update '.opnsense.unbound.enable=1' $config_path
    xml_update '.opnsense.unbound.forwarding=1' $config_path
    xml_update '.opnsense.unbound.active_interface="lan"' $config_path

    # Aliases
    ## Actual Allocated Public Networks (https://www.cidr-report.org | updates weekly)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    opnsense_aliases+='{"@uuid":"'$uuid'","enabled":1,"name":"PublicAllocatedNets_v4","type":"urltable","proto":{},"counters":0,"updatefreq":7,"content":"https://www.cidr-report.org/bogons/allocspace-prefix.txt","description":{}},'
    uuid=$(cat /proc/sys/kernel/random/uuid)
    opnsense_aliases+='{"@uuid":"'$uuid'","enabled":1,"name":"PublicAllocatedNets_v6","type":"urltable","proto":{},"counters":0,"updatefreq":7,"content":"https://www.cidr-report.org/bogons/allocspace-prefix6.txt","description":{}},'
    ## Internal Hosted Services (empty for now)
    uuid=$(cat /proc/sys/kernel/random/uuid)
    opnsense_aliases+='{"@uuid":"'$uuid'","enabled":1,"name":"HostedServices","type":"host","proto":{},"counters":0,"updatefreq":{},"content":{},"description":{}}'
    ## Commit changes
    xml_update '.opnsense.OPNsense.Firewall.Alias.aliases.alias=['$opnsense_aliases']' $config_path

    # Firewall
    ## NAT
    ### Port Forwarding
    opnsense_nat_rules+='{"protocol":"tcp","interface":"LANs","ipprotocol":"inet","descr":"Proxmox GUI","associated-rule-id":"nat_proxmox_gui","target":"'$PVE_MAN_IP'","local-port":8006,"source":{"any":1},"destination":{"network":"(self)","port":8006}},'
    opnsense_filter_rules+='{"protocol":"tcp","interface":"LANs","ipprotocol":"inet","descr":"Proxmox GUI","associated-rule-id":"nat_proxmox_gui","source":{"any":1},"destination":{"address":"'$PVE_MAN_IP'","port":8006}},'
    opnsense_nat_rules+='{"protocol":"tcp","interface":"LANs","ipprotocol":"inet","descr":"Proxmox SSH","associated-rule-id":"nat_proxmox_ssh","target":"'$PVE_MAN_IP'","local-port":22,"source":{"any":1},"destination":{"network":"(self)","port":8022}},'
    opnsense_filter_rules+='{"protocol":"tcp","interface":"LANs","ipprotocol":"inet","descr":"Proxmox GUI","associated-rule-id":"nat_proxmox_ssh","source":{"any":1},"destination":{"address":"'$PVE_MAN_IP'","port":22}},'

    ## Rules
    ### LANs ---> Internet via Failover
    opnsense_filter_rules+='{"type":"pass","interface":"LANs","ipprotocol":"inet","statetype":"keep state","descr":"IPv4 Use Failover Gateway for Internet Traffic","gateway":"Failover_v4","direction":"in","quick":1,"source":{"any":1},"destination":{"address":"PublicAllocatedNets_v4"}},'
    opnsense_filter_rules+='{"type":"pass","interface":"LANs","ipprotocol":"inet6","statetype":"keep state","descr":"IPv6 Use Failover Gateway for Internet Traffic","gateway":"Failover_v6","direction":"in","quick":1,"source":{"any":1},"destination":{"address":"PublicAllocatedNets_v6"}},'
    ### LANs <--> LANs
    opnsense_filter_rules+='{"type":"pass","interface":"LANs","ipprotocol":"inet46","statetype":"keep state","descr":"Default Allow","direction":"in","quick":1,"source":{"any":1},"destination":{"any":1}}'

    ## Commit
    xml_update '.opnsense.nat.rule=['${opnsense_nat_rules%?}']' $config_path
    xml_update '.opnsense.filter.rule=['$opnsense_filter_rules']' $config_path

    # ------------------------------------------------------------------------------- #
    #                      END OPNSENSE CONFIG.XML MODIFICATIONS                      #
    # ------------------------------------------------------------------------------- #

    console_message "Done modifying the OPNsense config file."
}

# Create init disk
bootstrap_opnsense() {
    console_message "Bootstrapping OPNsense to generate configuration values..."
    modprobe nbd max_part=8
    mkdir -p /var/lib/vz/images/$VM_ID
    if [ -f OPNsense-latest-OpenSSL-nano-amd64.qcow2 ]; then
        cp OPNsense-latest-OpenSSL-nano-amd64.qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2
    else
        cp OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2
        rm OPNsense-$OPNS_VER-OpenSSL-nano-amd64.qcow2
    fi

    # Get next free nbd device number 
    for x in /sys/class/block/nbd* ; do
        S=`cat $x/size`
        if [ "$S" == "0" ] ; then
            mnt_dev=/dev/`basename $x`
            break
        fi
    done
    mnt_point=/var/lib/vz/images/$VM_ID/mnt
    mkdir -p $mnt_point

    if [ ! -f /etc/pve/local/opnsense/conf/config.xml ]; then
        # Mount OPNsense Disk
        qemu-nbd --connect=$mnt_dev /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2
        while [ ! -b $mnt_dev ]; do sleep 1; done
        mount -t ufs -o ufstype=44bsd $mnt_dev $mnt_point

        # Set up conf directory
        mkdir -p /etc/pve/local/opnsense/conf/backup
        mkdir -p /etc/pve/local/opnsense/conf/sshd
        cp $mnt_point/usr/local/etc/config.xml /etc/pve/local/opnsense/conf/config.xml
        set_opnsense_base_config /etc/pve/local/opnsense/conf/config.xml

        # Unmount and disconnect OPNsense disk
        umount $mnt_point
        qemu-nbd --disconnect $mnt_dev
    fi

    console_message "Building Import Disk..."
    # Format Import Disk
    qemu-img create -f qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-1.qcow2 512M
    qemu-nbd --connect=$mnt_dev /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-1.qcow2
    while [ ! -b $mnt_dev ]; do sleep 1; done
    sgdisk $mnt_dev -n 1::1048509
    while [ ! -b $mnt_dev"p1" ]; do sleep 1; done
    mkfs.vfat -F32 $mnt_dev"p1"
    console_message "Mounting and copying config files..."
    # Mount partition and copy config data
    mount $mnt_dev"p1" $mnt_point
    cp -r /etc/pve/local/opnsense/conf $mnt_point/
    # Unmount and disconnect import disk
    umount $mnt_point
    qemu-nbd --disconnect $mnt_dev
    console_message "Creating Virtual Machine..."
    # Create the VM
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
        --vga serial0

    # Add Management interface to VM
    qm set $VM_ID --net0 virtio,bridge=$MAN_VMBR

    j=1
    # Add LAN bridges to VM
    for i in "${LAN_VMBRS[@]}"; do
        qm set $VM_ID --net$j virtio,bridge=$i
        ((j+=1))
    done
    # Add WAN bridges to VM
    for i in "${WAN_VMBRS[@]}"; do
        qm set $VM_ID --net$j virtio,bridge=$i
        ((j+=1))
    done
    # Add USB devices to VM
    j=0
    for i in "${USB_IDS[@]}"; do
        qm set $VM_ID --usb$j host=$i,usb3=1
        ((j+=1))
    done
    console_message "Done with the OPNsense bootstrap process."
}

init_opnsense() {
    # Start VM, import config, wait for login
    qm start $VM_ID
    console_message "Initilizing OPNsense virtual machine."
    /usr/bin/expect <(cat << EOF
set timeout -1
spawn qm terminal $VM_ID
expect {
    -exact "Press any key to start the configuration importer: " {
        send "\r"
        expect -exact "Select device to import from (e.g. ada0) or leave blank to exit: "
        send "vtbd1\r"
        expect -exact "login: "
        send "\x0F"
    }
    -exact "Press any key to start the manual interface assignment: " {
        expect -exact "login: "
        send "$OPN_USER\r"
        expect "Password:"
        send "$OPN_PASS\r"
        expect "Enter an option: "
        send "8\r"
        expect ":~ #"
        send "opnsense-importer"
        -exact "Select device to import from (e.g. ada0) or leave blank to exit: "
        send "vtbd1\r"
        expect ":~ #"
        send "exit\r"
        expect "Enter an option: "
        send "0\r"
        expect -exact "login: "
        send "\x0F"
    }
    "login:" {
        send "\x0F"
    }
}
EOF
)
    console_message "OPNsense virtual machine started."
}

first_time_ssh() {
    console_message "Checking SSH..."
    ssh_test=$(/usr/bin/expect <(cat << EOF
set timeout 10
log_user 0
spawn ssh $OPNSENSE_MAN_IP
expect {
    "(yes/no)? " {
        send "yes\r"
        expect ":~ #"
        send "exit\r"
    }
    ":~ #" {
        send "exit\r"
    }
    timeout {
        log_user 1
        puts "failed"
    }
}
EOF
))
    if [ -z "$ssh_test" ]; then 
        console_message "SSH up and working."
    else
        console_message "SSH isn't working."
        exit 6
    fi
}

update_opnsense() {
    console_message "Refreshing OPNsense Kernel and Signatures..."
    ssh_opnsense opnsense-update -i -kf
    console_message "Restarting OPNsense..."
    qm shutdown $VM_ID
    while [ "$(vm_opnsense_status)" != "stopped" ]; do sleep 1; done
    qm start $VM_ID
    terminal_opnsense_nowait
    install_opnsense_package "os-zerotier"
    install_opnsense_package "os-frr"
    console_message "Updating OPNsense Firmware..."
    terminal_opnsense_nowait "/usr/local/etc/rc.firmware upgrade `cat /usr/local/opnsense/firmware-upgrade`"
    terminal_opnsense_nowait
    console_message "Shutting Down OPNsense..."
    qm shutdown $VM_ID
    console_message "Caching and compressing the updated disk image..."
    qemu-img convert -c -O qcow2 /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2 OPNsense-latest-OpenSSL-nano-amd64.qcow2
    console_message "Starting OPNsense..."
    qm start $VM_ID
    while [ "$(vm_opnsense_status)" == "stopped" ]; do sleep 1; done
    terminal_opnsense_nowait
}

reset_opnsense() {
    # Start VM
    qm start $VM_ID
    echo ""
    echo "Resetting OPNsense to Defaults"
    echo ""
    terminal_opnsense_shell 4

    echo "Waiting for VM to stop..."
    while [ "$(vm_opnsense_status)" != "stopped" ]; do sleep 1; done

    echo "Caching updated disk image..."
    cp /var/lib/vz/images/$VM_ID/vm-$VM_ID-disk-0.qcow2 OPNsense-latest-OpenSSL-nano-amd64.qcow2
}

config_opnsense_zerotier() {
    console_message "Installing Zerotier..."
    install_opnsense_package "os-zerotier"
    if [ -d /etc/pve/local/opnsense/zerotier ]; then
        scp -r /etc/pve/local/opnsense/zerotier $OPNSENSE_MAN_IP:/var/db/zerotier-one
    fi

    config_path=/etc/pve/local/opnsense/config.xml
    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path
    xml_update '.opnsense.OPNsense.zerotier.enabled=1' $config_path
    xml_update '.opnsense.OPNsense.zerotier.apiAccessToken={}' $config_path
    if [ -f /etc/pve/local/opnsense/zerotier/local.conf ]; then
        zt_local=$(cat /etc/pve/local/opnsense/zerotier/local.conf)
        xml_update '.opnsense.OPNsense.zerotier.localconf="'$zt_local'"' $config_path
    else
        xml_update '.opnsense.OPNsense.zerotier.localconf="{}"' $config_path
    fi
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml

    terminal_opnsense configctl template reload OPNsense/zerotier
    terminal_opnsense configctl zerotier start
    console_message "Waiting for Zerotier to get online..."
    while [ "$(get_opnsense_zerotier_status)" != "ONLINE" ]; do sleep 1; done
    console_message "Joining the $ZT_ID network..."
    terminal_opnsense configctl zerotier join $ZT_ID

    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path
    uuid=$(cat /proc/sys/kernel/random/uuid)
    xml_update '.opnsense.OPNsense.zerotier.networks.network=[{"@uuid":"'$uuid'","enabled":1,"networkId":"'$ZT_ID'","description":{}}]' $config_path
    xml_update '.opnsense.interfaces.zt1={"if":"'$(get_opnsense_zerotier_network_interface $ZT_ID)'"}' $config_path
    xml_update '.opnsense.ifgroups.ifgroupentry=[(.opnsense.ifgroups.ifgroupentry[] | select (.ifname=="LANs") | .members+=" zt1"),(.opnsense.ifgroups.ifgroupentry[] | select (.ifname!="LANs"))]' $config_path
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml

    ZT_DEV=$(get_opnsense_zerotier_device_id)

    if [ "$(get_opnsense_zerotier_network_status $ZT_ID)" == "ACCESS_DENIED" ]; then
        console_message "Access to the Zerotier network is currently denied for this device. Log into my.zerotier.com and approve this device ($ZT_DEV) on the $ZT_ID network. Waiting indefinitely until this device is approved..."
        while [ "$(get_opnsense_zerotier_network_status $ZT_ID)" == "ACCESS_DENIED" ]; do sleep 1; done
    fi
    ZT_CIDR=$(get_opnsense_zerotier_network_cidr $ZT_ID)
    if [ "$ZT_CIDR" == "null" ]; then
        console_message "No IP defined for this device on the Zerotier network. Log into my.zerotier.com and give this device ($ZT_DEV) an IP on the $ZT_ID network. Waiting indefinitely until this device is given an IP..."
        while [ "$ZT_CIDR" == "null" ]; do ZT_CIDR=$(get_opnsense_zerotier_network_cidr $ZT_ID); done
        terminal_opnsense configctl zerotier leave $ZT_ID
        console_message "Rebooting OPNsense. Please wait..."
        reboot_opnsense
        terminal_opnsense configctl zerotier join $ZT_ID
    fi
    console_message "Connected as $ZT_CIDR via $ZT_ID!"
    # Convert ZT_CIDR to array
    if [[ "$ZT_CIDR" == *","* ]]; then 
        IFS=',' read -r -a ZT_CIDR <<< "$ZT_CIDR"
    else
        ZT_CIDR=($ZT_CIDR)
    fi

    OPNSENSE_ZT1_IP=$(echo ${ZT_CIDR[0]} | awk -F/ '{print $1}')
    ZT_MASK=$(echo ${ZT_CIDR[0]} | awk -F/ '{print $2}')

    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path
    xml_update '.opnsense.interfaces.zt1.enable=1' $config_path
    xml_update '.opnsense.interfaces.zt1.ipaddr="'$OPNSENSE_ZT1_IP'"' $config_path
    xml_update '.opnsense.interfaces.zt1.subnet="'$ZT_MASK'"' $config_path
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml
    terminal_opnsense configctl interface reconfigure zt1
    
    ZT_MIN_IP=$(ipcalc ${ZT_CIDR[0]} | grep HostMin | awk '{print $2}')
    ZT_MAX_IP=$(ipcalc ${ZT_CIDR[0]} | grep HostMax | awk '{print $2}')
    ZT_BC_IP=$(ipcalc ${ZT_CIDR[0]} | grep Broadcast | awk '{print $2}')
    
    config_opnsense_router_discovery
    config_opnsense_router
    
    scp -r $OPNSENSE_MAN_IP:/var/db/zerotier-one /etc/pve/local/opnsense/zerotier
}
config_opnsense_router_discovery() {
    config_path=/etc/pve/local/opnsense/config.xml

    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path
    xml_update '.opnsense.nat.outbound.mode="hybrid"' $config_path
    xml_update '.opnsense.nat.outbound.rule=[{"source":{"network":"lan"},"destination":{"network":"zt1"},"interface":"zt1","ipprotocol":"inet","target":{},"targetip_subnet":0}]' $config_path
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml
    reload_opnsense_services

    console_message "Searching for DNS provider on Zerotier network..."
    echo -n "Trying..."
    DNS=$ZT_MIN_IP
    while ! ding $DNS; do
        echo -n .
        DNS=$(ip_shift $DNS +1)
        if [ "$DNS" = "$ZT_BC_IP" ]; then
            console_message "Tried every IP in the Zerotier subnet, and no DNS was found. A pre-configured DNS is required for deployment orchestration."
            exit 6
        fi
    done
    echo " Found @$DNS!"
    PTR=$(dig @$DNS -x $OPNSENSE_ZT1_IP +short)
    console_message "FQDN: $PTR"
    opnsense_domain=$(echo $PTR | awk -F. '{$1=""; print $0}' | xargs | sed 's/\s/\./g')
    opnsense_hostname=$(echo $PTR | awk -F. '{print $1}')
    DOMAIN_NAME=$(echo $PTR | awk -F. '{print $(NF-2)"."$(NF-1)}')
    if [ ! -z "$DOMAIN_NAME" ]; then echo search $(echo $DOMAIN_NAME) >> /etc/resolv.conf; fi
    console_message "Welcome to the '$DOMAIN_NAME' domain!"
}
config_opnsense_router() {
    config_path=/etc/pve/local/opnsense/config.xml
    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path
    
    # Hostname
    xml_update '.opnsense.system.hostname="'$opnsense_hostname'"' $config_path
    xml_update '.opnsense.system.domain="'$opnsense_domain'"' $config_path
    
    i=1
    for CIDR in "${ZT_CIDR[@]}"; do
        zt_ip=$(echo $CIDR | awk -F/ '{print $1}')
        enum=$(echo $zt_ip | awk -F. '{print $4}')
        lan_cidr=$ZT_LAN_MAP
        lan_mask=$(echo $lan_cidr | awk -F/ '{print $2}')
        for (( c=1; c<=$enum; c++)); do
            lan_cidr=$(ip_shift $(ipcalc $lan_cidr | grep Broadcast | awk '{print $2}') +1)/$lan_mask
        done
        lan_ip=$(ipcalc $lan_cidr | grep HostMin | awk '{print $2}')

        console_message "Configuring LAN$i as $lan_cidr..."

        # LAN Interfaces
        xml_update '.opnsense.interfaces.lan'$i'.ipaddr="'$lan_ip'"' $config_path
        xml_update '.opnsense.interfaces.lan'$i'.subnet="'$lan_mask'"' $config_path
        # DHCP
        dhcp_mask=$(($lan_mask+1))
        dhcp_from=$(ip_shift $(ipcalc $lan_ip/$dhcp_mask | grep Broadcast | awk '{print $2}') +2)
        dhcp_to=$(ipcalc $lan_cidr | grep HostMax | awk '{print $2}')
        xml_update '.opnsense.dhcpd.lan'$i'={"enable":{},"range":{"from":"'$dhcp_from'","to":"'$dhcp_to'"},"domain":"'$DOMAIN_NAME'","domainsearchlist":"'$DOMAIN_NAME'"}' $config_path
        # VirtualIP
        if [ "$zt_ip" != "$OPNSENSE_ZT1_IP" ]; then
            console_message "$zt_ip is not the primary IP address for the Zerotier network ($ZT_ID) and will be added as a Virtual IP."
        fi
        ((i+=1))
    done
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml
    reload_opnsense_services
    while ! ping -c 1 -n -w 1 google.com &> /dev/null; do sleep 1; done
    config_opnsense_frr
}
config_opnsense_frr() {
    console_message "Installing Free Range Routing..."
    config_path=/etc/pve/local/opnsense/config.xml
    scp $OPNSENSE_MAN_IP:/conf/config.xml $config_path

    xml_update '.opnsense.OPNsense.quagga.general.enabled=1' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.enabled=1' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.routerid="'$OPNSENSE_ZT1_IP'"' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.originatemetric={}' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.passiveinterfaces="WANs"' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.redistribute="connected"' $config_path
    xml_update '.opnsense.OPNsense.quagga.ospf.redistributemap={}' $config_path
    
    uuid=$(cat /proc/sys/kernel/random/uuid)
    ospf_interfaces='{"@uuid":"'$uuid'","enabled":1,"interfacename":"zt1","authtype":{},"authkey":{},"authkey_id":1,"area":"0.0.0.0","cost":{},"hellointerval":{},"deadinterval":{},"retransmitinterval":{},"transmitdelay":{},"priority":{},"networktype":{}}'
    xml_update '.opnsense.OPNsense.quagga.ospf.interfaces.interface=['$ospf_interfaces']' $config_path
    
    scp $config_path $OPNSENSE_MAN_IP:/conf/config.xml
    
    terminal_opnsense configctl template reload OPNsense/Quagga
    terminal_opnsense configctl quagga start
}

reset_opnsense_base_config(){
    config_path=/etc/pve/local/opnsense/conf
    scp $config_path/* $OPNSENSE_MAN_IP:/conf/
    reboot_opnsense
}

reload_opnsense_services() {
    terminal_opnsense /usr/local/etc/rc.reload_all
}
reboot_opnsense() {
    terminal_opnsense_nowait reboot
    terminal_opnsense_nowait
}

get_opnsense_zerotier_status() {
    terminal_opnsense zerotier-cli status  | \
    awk '{print $5}' | \
    tr -d '\040\011\012\015'
}
get_opnsense_zerotier_device_id() {
    terminal_opnsense zerotier-cli status | \
    awk '{print $3}' | \
    tr -d '\040\011\012\015'
}
get_opnsense_zerotier_network_status() {
    echo $(terminal_opnsense configctl zerotier listnetworks_json) | \
    jq -r '.[] | select(.id="'$1'") | .status'
}
get_opnsense_zerotier_network_interface() {
    echo $(terminal_opnsense configctl zerotier listnetworks_json) | \
    jq -r '.[] | select(.id="'$1'") | .portDeviceName'
}
get_opnsense_zerotier_network_cidr() {
    output=$(terminal_opnsense configctl zerotier listnetworks_json | jq -r '.[] | select(.id="'$1'") | .assignedAddresses[]')
    if [ -z "$output" ]; then echo "null"; else echo "$output"; fi
}

if [ "$1" = "reset-config" ]; then 
    reset_opnsense_base_config
    exit
fi

# Prerequisites
backup_networking
init_temp_internet
get_prerequisites

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
bootstrap_network
prepare_ssh_key
bootstrap_opnsense
init_opnsense
first_time_ssh
update_opnsense

# OPNsense Zerotier Config
config_opnsense_zerotier

console_message "Finished setting up OPNsense!"
