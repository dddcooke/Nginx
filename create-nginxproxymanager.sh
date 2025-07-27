#!/bin/bash

# Ask for container ID
read -p "Enter CTID (e.g. 152): " CTID

# Ask for network type
read -p "Use DHCP or Static IP? [dhcp/static]: " NETTYPE

if [[ "$NETTYPE" == "static" ]]; then
    read -p "Enter static IP (e.g. 10.1.0.100/24): " STATICIP
    IPCONF="ip=$STATICIP,gw=10.1.0.1"
else
    IPCONF="ip=dhcp"
fi

# Download template if needed
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
if ! ls /var/lib/vz/template/cache/$TEMPLATE >/dev/null 2>&1; then
    echo "Downloading Debian 12 template..."
    pveam download local $TEMPLATE
fi

# Create the container
pct create $CTID local:vztmpl/$TEMPLATE \
  --hostname nginxproxymanager \
  --cores 2 --memory 2048 \
  --net0 name=eth0,bridge=vmbr0,$IPCONF \
  --unprivileged 1 --rootfs local-lvm:8 || { echo "Container creation failed"; exit 1; }

# Append LXC options
cat <<EOF >> /etc/pve/lxc/$CTID.conf
lxc.apparmor.profile: unconfined
lxc.cap.drop: 
lxc.cgroup.devices.allow: a
lxc.mount.auto: proc:rw sys:rw
lxc.apparmor.allow_nesting: 1
EOF

# Start container
pct start $CTID
sleep 5

# Install Docker, Docker Compose, and clone from GitHub
pct exec $CTID -- bash -c "
apt update && apt install -y curl ca-certificates gnupg lsb-release git &&
curl -fsSL https://get.docker.com | sh &&
apt install -y docker-compose &&
mkdir -p /opt/npm &&
cd /opt &&
git clone https://github.com/dddcooke/Nginx.git &&
cp /opt/Nginx/docker-compose.yml /opt/npm/ &&
ls -l /opt/npm &&
docker-compose -f /opt/npm/docker-compose.yml up -d
"

# Start NPM container
pct exec $CTID -- bash -c "cd /opt/npm && docker-compose up -d"

echo "✅ Nginx Proxy Manager container $CTID created and running."
