#!/bin/bash

# Script to create VM with specified name and IP
# Usage: create-vm.sh <VM_NAME> <VM_IP> <VM_HOSTNAME>

set -e
set -o pipefail

VM_NAME="${1}"
VM_IP="${2}"
VM_HOSTNAME="${3}"

if [ -z "$VM_NAME" ] || [ -z "$VM_IP" ] || [ -z "$VM_HOSTNAME" ]; then
    echo "Usage: $0 <VM_NAME> <VM_IP> <VM_HOSTNAME>"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGES_DIR="$PROJECT_ROOT/data/images"
KEYS_DIR="$PROJECT_ROOT/data/keys"
SEEDCONFIG_DIR="$PROJECT_ROOT/config/seedconfig"

# Load variables to get VM_PASSWORD
if [ -f "$PROJECT_ROOT/config/variables.sh" ]; then
    source "$PROJECT_ROOT/config/variables.sh"
fi

VM_USER=ubuntu
VM_IMAGE=ubuntu-root.img
VM_IMAGE_FORMAT=img
VM_IMAGE_TEMPLATE=ubuntu-template.img
VM_IMAGE_LINK=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

IMAGE_SIZE=20g
VM_MEMORY=2048
VM_CPUS=2

# Check root privileges
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Check if VM exists
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    echo "VM ${VM_NAME} already exists, skipping creation"
    exit 0
fi

echo "Creating VM: ${VM_NAME} with IP: ${VM_IP} and hostname: ${VM_HOSTNAME}"

# 1. Get image (if not already downloaded)
if [ ! -f "$IMAGES_DIR/$VM_IMAGE_TEMPLATE" ]; then
    echo "Downloading Ubuntu image..."
    mkdir -p "$IMAGES_DIR"
    if ! wget -O "$IMAGES_DIR/$VM_IMAGE_TEMPLATE" "$VM_IMAGE_LINK"; then
        echo "Error: Failed to download image"
        exit 1
    fi
fi

# 2. Create directories
mkdir -p /var/lib/libvirt/images/
mkdir -p "$SEEDCONFIG_DIR"

# 3. Copy image for this VM
VM_IMAGE_PATH="/var/lib/libvirt/images/${VM_NAME}-${VM_IMAGE}"
if [ ! -f "$VM_IMAGE_PATH" ]; then
    echo "Copying image for ${VM_NAME}..."
    cp "$IMAGES_DIR/$VM_IMAGE_TEMPLATE" "$VM_IMAGE_PATH"
    qemu-img resize "$VM_IMAGE_PATH" "$IMAGE_SIZE" &>/dev/null
fi

# 4. Create additional disk
DISK_NAME="${VM_NAME}-disk.qcow2"
if [ ! -f "/var/lib/libvirt/images/$DISK_NAME" ]; then
    echo "Creating additional disk for ${VM_NAME}..."
    qemu-img create -f qcow2 "/var/lib/libvirt/images/$DISK_NAME" 25G &>/dev/null
fi

# 5. Generate SSH keys (if not already created)
if [ ! -f "$KEYS_DIR/rsa.key" ]; then
    echo "Generating SSH keys..."
    mkdir -p "$KEYS_DIR"
    ssh-keygen -f "$KEYS_DIR/rsa.key" -t rsa -N "" > /dev/null
    chmod 600 "$KEYS_DIR/rsa.key"
    chmod 644 "$KEYS_DIR/rsa.key.pub"
fi

# 6. Create cloud-init configuration with static IP
echo "Creating cloud-init configuration for ${VM_NAME}..."
cat > "$SEEDCONFIG_DIR/${VM_NAME}-user-data" <<EOF
#cloud-config
#vim:syntax=yaml
users:
  - name: ${VM_USER}
    gecos: Kubernetes Node
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: ${VM_PASSWORD:-$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)}
    groups: sudo, admin
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat "$KEYS_DIR/rsa.key.pub")
hostname: ${VM_HOSTNAME}
fqdn: ${VM_HOSTNAME}.local
manage_etc_hosts: true
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: false
      addresses:
        - ${VM_IP}/24
      gateway4: 192.168.122.1
      nameservers:
        addresses:
          - 8.8.8.8
          - 8.8.4.4
EOF

cat > "$SEEDCONFIG_DIR/${VM_NAME}-meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_HOSTNAME}
EOF

# 7. Create ISO for cloud-init
echo "Creating cloud-init ISO for ${VM_NAME}..."
if ! genisoimage \
    -output "/var/lib/libvirt/images/${VM_NAME}-seed.iso" \
    -volid cidata \
    -joliet \
    -rock \
    "$SEEDCONFIG_DIR/${VM_NAME}-user-data" \
    "$SEEDCONFIG_DIR/${VM_NAME}-meta-data" &>/dev/null; then
    echo "Error: Failed to create ISO"
    exit 1
fi

# 8. Create VM
echo "Creating VM ${VM_NAME}..."
if ! virt-install \
    --name "${VM_NAME}" \
    --memory "${VM_MEMORY}" \
    --vcpus "${VM_CPUS}" \
    --disk "path=${VM_IMAGE_PATH},format=${VM_IMAGE_FORMAT}" \
    --disk "path=/var/lib/libvirt/images/${VM_NAME}-seed.iso,device=cdrom" \
    --disk "path=/var/lib/libvirt/images/${DISK_NAME},format=qcow2" \
    --os-variant ubuntu22.04 \
    --virt-type kvm \
    --graphics none \
    --console pty,target_type=serial \
    --network network=default \
    --noautoconsole \
    --import &>/dev/null; then
    echo "Error: Failed to create VM"
    exit 1
fi

# 9. Wait for VM to start
echo "Waiting for VM ${VM_NAME} to start..."
for i in {1..60}; do
    if virsh domifaddr "${VM_NAME}" 2>/dev/null | grep -q "ipv4"; then
        ACTUAL_IP=$(virsh domifaddr "${VM_NAME}" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
        echo "VM ${VM_NAME} is running on ${ACTUAL_IP}"
        exit 0
    fi
    sleep 2
done

echo "Warning: VM ${VM_NAME} did not get IP address in time, but VM was created"
exit 0

