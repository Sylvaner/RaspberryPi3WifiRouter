#!/bin/sh

prompt_network() {
	echo "WiFi network : "
	echo "1. 192.168.1.0/24 (Gateway 192.168.1.254)"
	echo "2. 192.168.0.0/24 (Gateway 192.168.0.254)"
	echo "3. Custom"
	while true; do
		read network_choice
		case $network_choice in
			[1]*) GATEWAY=192.168.1.254
			      NETWORK=192.168.1.0
			      RANGE_FIRST=192.168.1.1
			      RANGE_LAST=192.168.1.253
			      return;; 
			[2]*) GATEWAY=192.168.0.254
			      NETWORK=192.168.0.0
			      RANGE_FIRST=192.168.0.1
			      RANGE_LAST=192.168.0.253
			      return;;
			[3]*) read -p "Gateway address (192.168.1.254) : " GATEWAY
			      read -p "Network (192.168.1.0) : " NETWORK
			      read -p "DHCP range first address (192.168.1.1) : " RANGE_FIRST
			      read -p "DHCP range last address (192.168.1.253) : " RANGE_LAST
			      return;;
		esac
	done	
}

prompt_yn() {
	while true; do
		read answer
		case $answer in
			[Yy]*) return 1;;
			[Nn]*) return 0;;
		esac
	done
}

config() {
	read -p "Wi-Fi name : " SSID
	read -p "Wi-Fi password : " PASSWORD
	prompt_network	
	echo "Block connections ? [y/n]"
	prompt_yn
	FILTER_INSTALL=$?
	echo "Install web interface (Webmin) ? [y/n]"
	prompt_yn
	WEBMIN_INSTALL=$?

	echo 
	echo "====================="
	echo "=== Configuration ==="
	echo "====================="
	echo "SSID : $SSID"
	echo "Wi-Fi Password : $PASSWORD"
	echo "Gateway address : $GATEWAY"
	echo "Network : $NETWORK/24"
	echo "DHCP range : $RANGE_FIRST - $RANGE_LAST" 
	if [ $FILTER_INSTALL -eq 1 ]; then
		echo "Install iptables rules."
	fi
	if [ $WEBMIN_INSTALL -eq 1 ]; then
		echo "Install Webmin."
	fi
	echo
	echo "Apply this configuration ? [y/n] : "
	if prompt_yn; then
		exit
	fi
}

# Test kernel issues if apt-upgrade was launched
sudo iptables -L > /dev/null 2>&1
if [ $? -ne 0 ]; then
	echo "Problem with iptables, you must upgrade the kernel. The raspberry pi will reboot automatically.\nUpgrade the kernel ? [y/n]"
	if prompt_yn; then
		exit	
	else
		sudo apt-get install -y rpi-update
		sudo rpi-update
		sudo reboot
	fi
fi

config
# Start of the script
mkdir /tmp/install

# Update of the packages
sudo apt-get update
#sudo apt-get -y upgrade

# Package installation

# dnsmasq configuration
sudo apt-get install -y dnsmasq
touch /tmp/install/dnsmasq.conf
cat << EOF_DNSMASQ >> /tmp/install/dnsmasq.conf
no-resolv
interface=wlan0
dhcp-range=$RANGE_FIRST,$RANGE_LAST,12h
server=80.67.169.12
server=80.67.169.40
EOF_DNSMASQ
sudo cp -fr /tmp/install/dnsmasq.conf /etc/dnsmasq.conf

# Configure wifi interface
touch /tmp/install/interfaces
cat << EOF_INTERFACES >> /tmp/install/interfaces
# Include files from /etc/network/interfaces.d:
source-directory /etc/network/interfaces.d

auto lo

iface lo inet loopback

iface eth0 inet manual

allow-hotplug wlan0
iface wlan0 inet static
    address $GATEWAY
    netmask 255.255.255.0
EOF_INTERFACES
sudo cp -fr /tmp/install/interfaces /etc/network/interfaces

sudo ifconfig wlan0 $GATEWAY

# Configure hostapd
sudo apt-get install -y hostapd
touch /tmp/install/hostapd.conf
cat << EOF_HOSTAPD >> /tmp/install/hostapd.conf
interface=wlan0
driver=nl80211
ssid=$SSID
channel=1
wme_enabled=1
wpa=2
wpa_passphrase=$PASSWORD
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
auth_algs=1
macaddr_acl=0
ieee80211n=1
hw_mode=g
EOF_HOSTAPD
sudo cp -fr /tmp/install/hostapd.conf /etc/hostapd/hostapd.conf
sudo sed -i 's/#DAEMON_CONF=""/DAEMON_CONF="\/etc\/hostapd\/hostapd.conf"/g' /etc/default/hostapd

# Configure NAT
sudo sh -c "echo 'net.ipv4.ip_forward=1' >> /etc/sysctl.conf"
sudo sh -c "echo 1 > /proc/sys/net/ipv4/ip_forward"

# Configure firewall
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections

sudo apt-get install -y iptables-persistent
# Clear iptables
sudo iptables -F
sudo iptables -X
sudo iptables -t nat -F
sudo iptables -t nat -X

if [ $FILTER_INSTALL -eq 1 ]; then
	# Input on the router
	sudo iptables -A INPUT -i wlan0 -p udp --dport 53 -j ACCEPT
	sudo iptables -A INPUT -i wlan0 -p udp --dport 67 -j ACCEPT
	sudo iptables -A INPUT -i wlan0 -p tcp --dport 10000 -j ACCEPT
	sudo iptables -A INPUT -i wlan0 -j DROP

	# Open port to the web
	sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
	sudo iptables -A FORWARD -i wlan0 -o eth0 -p tcp --dport 80 -j ACCEPT
	sudo iptables -A FORWARD -i wlan0 -o eth0 -p tcp --dport 443 -j ACCEPT
	sudo iptables -A FORWARD -i wlan0 -o eth0 -j DROP

	# Marquerade on ouput
	sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
else
	# Allow all
	sudo iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE
	sudo iptables -A FORWARD -i eth0 -o wlan0 -m state --state RELATED,ESTABLISHED -j ACCEPT
	sudo iptables -A FORWARD -i wlan0 -o eth0 -j ACCEPT
fi

# Accept all from local
sudo iptables -A INPUT -i eth0 -j ACCEPT

sudo sh -c "iptables-save > /etc/iptables/rules.v4"

# Install webmin
if [ $WEBMIN_INSTALL -eq 1 ]; then
	sudo apt-get install -y libnet-ssleay-perl libauthen-pam-perl libio-pty-perl apt-show-versions libapt-pkg-perl
	wget http://prdownloads.sourceforge.net/webadmin/webmin_1.820_all.deb -O /tmp/install/webmin.deb
	sudo dpkg -i /tmp/install/webmin.deb
fi

rm -fr /tmp/install

sudo reboot

