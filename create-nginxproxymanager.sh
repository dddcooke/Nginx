#!/bin/bash

echo "📦 Proxmox LXC NGINX Proxy Manager Setup"
echo "----------------------------------------"

# Suggest next available CTID but allow override
SUGGESTED_CTID=$(for i in $(seq 100 999); do pct status $i >/dev/null 2>&1 || { echo $i; break; }; done)
read -p "Enter CTID to use [$SUGGESTED_CTID]: " CTID
CTID=${CTID:-$SUGGESTED_CTID}

# Get hostname (optional)
read -p "Enter hostname [nginxproxymanager]: " HOSTNAME
HOSTNAME=${HOSTNAME:-nginxproxymanager}

# Network type
echo "Select Network Type:"
select NETTYPE in "DHCP" "Static IP"; do
    case $NETTYPE in
        "DHCP" )
            IPCONFIG="ip=dhcp"
            break
            ;;
        "Static IP" )
            read -p "Enter Static IP (e.g., 10.1.0.100/24): " STATICIP
            read -p "Enter Gateway IP (e.g., 10.1.0.1): " GATEWAY
            IPCONFIG="ip=$STATICIP,gw=$GATEWAY"
            break
            ;;
    esac
done

# Confirm settings
echo ""
echo "✅ Summary:"
echo "  CTID:       $CTID"
echo "  Hostname:   $HOSTNAME"
echo "  Network:    $IPCONFIG"
echo ""

read -p "Proceed with container creation? [y/N]: " CONFIRM
[[ "$CONFIRM" =~ ^[Yy]$ ]] || exit 1

# Download template if needed
TEMPLATE="debian-12-standard_12.7-1_amd64.tar.zst"
if ! ls /var/lib/vz/template/cache/$TEMPLATE >/dev/null 2>&1; then
    echo "📥 Downloading Debian 12 template..."
    pveam download local $TEMPLATE
fi

# Create container
echo "🚀 Creating LXC Container..."
pct create $CTID local:vztmpl/$TEMPLATE \
  --hostname $HOSTNAME \
  --cores 2 --memory 2048 \
  --net0 name=eth0,bridge=vmbr0,$IPCONFIG \
  --unprivileged 1 --rootfs local-lvm:8 || { echo "❌ Container creation failed"; exit 1; }

# Add necessary LXC options
echo "🔧 Applying LXC advanced options..."
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

# Optional: grant root access
read -p "🔐 Add Proxmox root SSH key to container for root login? [y/N]: " ROOT_SSH
if [[ "$ROOT_SSH" =~ ^[Yy]$ ]]; then
    echo
    read -s -p "Enter new root password (leave blank to skip): " ROOTPW
    echo
    if [[ -n "$ROOTPW" ]]; then
        echo "🔐 Setting root password..."
        echo "root:$ROOTPW" | pct exec $CTID -- chpasswd
    fi

    echo "📤 Injecting root SSH access from host..."

    pct exec $CTID -- bash -c "
      apt update &&
      apt install -y openssh-server &&
      mkdir -p /root/.ssh &&
      chmod 700 /root/.ssh
    "

    HOST_SSH_KEY=$(cat /root/.ssh/id_rsa.pub 2>/dev/null)
    if [[ -z "$HOST_SSH_KEY" ]]; then
        echo "⚠️ No /root/.ssh/id_rsa.pub found on host. Skipping key injection."
    else
        pct exec $CTID -- bash -c "echo \"$HOST_SSH_KEY\" >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys"
        pct exec $CTID -- bash -c "sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config"
        pct exec $CTID -- bash -c "sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config"
        pct exec $CTID -- systemctl restart ssh
        echo "✅ Root SSH access enabled for container $CTID"
    fi
fi

# Install Docker, Docker Compose, and pull GitHub file
echo "🐳 Installing Docker and setting up NPM..."
pct exec $CTID -- bash -c "
apt update &&
apt install -y curl ca-certificates gnupg lsb-release git docker-compose &&
curl -fsSL https://get.docker.com | sh &&
mkdir -p /opt/npm &&
cd /opt &&
git clone https://github.com/dddcooke/Nginx.git &&
cp /opt/Nginx/docker-compose.yml /opt/npm/
"

# Start docker-compose
echo "🚀 Launching Nginx Proxy Manager container..."
pct exec $CTID -- bash -c "cd /opt/npm && docker-compose up -d"

# Final status
echo ""
echo "✅ Done! Nginx Proxy Manager is running inside LXC container $CTID"
echo "➡ Access it via http://<IP>:81 (default login: admin@example.com / changeme)"
