# wonderwall
Script to help automate installing and configuring OPNsense on Proxmox

## Script Options
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
        Example:     ens1
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
        Example:     eth0,eth1,eth2,eth3
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

## Zerotier Configuration

Zerotier is used in this project to make setting up multisite-to-multisite VPNs brain-dead simple.  In this project it is also used to route traffic from a VPS with a dedicated public IP address to internally hosted services - because that's typically cheaper than having your ISP provide you with one.

Although I say the setup is braindead simple, I'm going deliberately be as verbose as possible when describing the configuration.

If you're not familiar with Zerotier, essentially, it creates an end-to-end encrypted virtual layer 2 network. Imagine it as a private ethernet switch that works over the Internet. If nothing more, at least read the cryptography section https://www.zerotier.com/manual/#2_1_3 before continuing.

### Login

* Set up an account at https://my.zerotier.com
* Click "Log in to Zerotier"
* Either log in with you Google account, or register a new account.

### Networks

Once logged in, click on "Networks" from the navigation menu.
* Click "Create a Network"
* You will see it added to the "Your Networks" list.
* Note the network's ID. It will be used with the --zt-net-id option.
* Click on the newly created network's ID to get to the settings page.

It should bring you directly to the "Members" section. One of the nice things about Zerotier is that the networks you create can be either "Private" or "Public". By default networks are private. Private networks require all devices to be explicitely approved before they can join the network. This means that even if your network ID is unintentionally leaked, unauthorized devices will not be able to join the network without you loging in to your Zerotier account and granting access. At this point, though, don't worry about adding "Members" to the network yet. That will happen automatically when you run the setup.sh script. 

### Routing

We'll need to add a route for the Zerotier clients to talk to each other. You can use any subnet you want that won't conflict with other networks you plan to have set up. It also can't conflict with any of the default subnet configured in the DHCP service on the majority of consumer routers. For simplicity sake, follow the steps below.

* Scroll to the "Advanced" section.
* Under "IPv4 Auto-Assign", make sure "Auto-Assign from Range" is enabled.
* Make sure "Easy" is selected.
* Select one of the following options:
   * 192.168.191.*
   * 192.168.192.*
   * 192.168.193.*
   * 192.168.194.*
   * 192.168.195.*
   * 192.168.196.*

Do not worry about adding any other routes. WondwerWall will automatically configure Free Range Routing (FFR) in OPNsense and will dynamically configure routing paths to each site over the Zerotier network.
