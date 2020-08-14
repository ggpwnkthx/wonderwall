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

Note: For performance (encryption) reasons, the setup.sh script installs Zerotier on the host, not in the OPNsense VM.

### Login

* Set up an account at https://my.zerotier.com
* Click "Log in to Zerotier"
* Either log in with you Google account, or register a new account.

### Networks

Once logged in, click on "Networks" from the navigation menu.
* Click "Create a Network"
* You will see it added to the "Your Networks" list.
* Note the network's ID and replace the xxxxxxxxxxxxxxxx in the setup.sh file with that ID.
* Click on the newly created network's ID to get to the settings page

It should bring you directly to the "Members" section. One of the nice things about Zerotier is that the networks you create can be either "Private" or "Public". By default networks are private. Private networks require all devices to be explicitely approved before they can join the network. This means that even if your network ID is unintentionally leaked, unauthorized devices will not be able to intercept network traffic. At this point, though, don't worry about adding "Members" to the network yet. That will happen automatically when you run the setup.sh script. 

In most cases, the default settings are usually fine, however, for this project we want to set up static routes for each site so that each site's LAN can communicate with each other.

* Scroll up to the "Advanced" section.
* Delete (press the blue trashcan) any autogenerated networks in the Managed Routes list
* Under "IPv4 Auto-Assign", disable "Auto-Assign from Range"

#### Primary Route

First we'll add a route only for the host machines connecting directly to our Zerotier network. You can use any subnet you want that won't conflict with other networks you plan to have set up. As an example, I'm going to use 10.1.0.0/22. This will provide a huge range of IP addresses (Zeroteir allows up to 100 clients to connect for free) that we can use. It also shouldn't conflict with the default subnet configured in the DHCP service on the majority of consumer routers.

* Scroll back to "Managed Routes"
* Under "Add Route", in the "Destination" box put: 10.1.0.0/22
* Leave "(via)" blank
* Press "Submit"
* You should see the new route added to the route list.

#### Site Routes

If you don't plan to have multiple sites that need to communicate with each other, you can ignore this section.

Since we will eventually set up each of our Zeroteir network's "Members" with a static IP address, we can plan out our site routes with realtive ease. For organizational reasons, I like to use a pattern to match the IP address of the "Member" with the subnet of the LAN it will route to/from. For example, since we have the 10.1.0.0/22 range to work with, if I set a member's IP to 10.1.1.5, I'll set up it's site LAN to use the subnet 10.5.0.0/16. The pattern, in this case being:

* If the 3rd octet in the Member's IP address is a 1, that signifies it's a site router.
* The 4th octet in the Member's IP address matches the the 2nd octet in the subnet of that site's LAN.

Examples:

 * If Member IP is 10.1.1.2, set LAN_CIDR=10.2.0.0/16
 * If Member IP is 10.1.1.3, set LAN_CIDR=10.3.0.0/16
 * If Member IP is 10.1.1.4, set LAN_CIDR=10.4.0.0/16
 * If Member IP is 10.1.1.5, set LAN-CIDR=10.5.0.0/16
 * ...etc

Note: Using class A addresses and 16 bit netmasks is probably unecessary for home networks. If you have 64k devices at each home... I... don't know what to say.

Let's set up our Zerotier network to route between for 4 different sites:

- Scroll back to "Managed Routes"
- For the first site:
  - Under "Add Route", in the "Destination" box put: 10.2.0.0/16
  - In the "(via)" box put: 10.1.1.2
  - Press "Submit"
- For the second site:
  - Under "Add Route", in the "Destination" box put: 10.3.0.0/16
  - In the "(via)" box put: 10.1.1.3
  - Press "Submit"
- For the third site:
  - Under "Add Route", in the "Destination" box put: 10.4.0.0/16
  - In the "(via)" box put: 10.1.1.4
  - Press "Submit"
- For the fourth site:
  - Under "Add Route", in the "Destination" box put: 10.5.0.0/16
  - In the "(via)" box put: 10.1.1.5
  - Press "Submit"
- You should see 5 routes. The primary route, and a route for our 4 sites.

That's it!

Other than setting the variables in the setup.sh script, manually approving a device that joins the Zerotier network and giving it a static IP address, everything else is fully automated.
