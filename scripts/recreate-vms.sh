#!/bin/bash

# Скрипт для пересоздания всех VM кластера Kubernetes

set -e
set -o pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Проверка прав root
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Загрузка переменных
if [ ! -f "$PROJECT_ROOT/config/variables.sh" ]; then
    echo "Error: variables.sh not found"
    exit 1
fi
source "$PROJECT_ROOT/config/variables.sh"

echo "=========================================="
echo "Kubernetes Cluster VM Recreation"
echo "=========================================="
echo ""

# Шаг 1: Удаление всех существующих VM
echo "Step 1: Cleaning up existing VMs..."
if [ -f "$SCRIPT_DIR/cleanup-vms.sh" ]; then
    chmod +x "$SCRIPT_DIR/cleanup-vms.sh"
    "$SCRIPT_DIR/cleanup-vms.sh" || {
        echo "Warning: Cleanup had some issues, continuing..."
    }
else
    echo "Warning: cleanup-vms.sh not found, skipping cleanup"
fi

echo ""
echo "Step 2: Setting up libvirt network..."
if [ ! -f "$SCRIPT_DIR/setup-libvirt-network.sh" ]; then
    echo "Error: setup-libvirt-network.sh not found"
    exit 1
fi
chmod +x "$SCRIPT_DIR/setup-libvirt-network.sh"
"$SCRIPT_DIR/setup-libvirt-network.sh" || {
    echo "Error: Failed to setup libvirt network"
    exit 1
}

echo ""
echo "Step 3: Creating VM nodes..."
if [ ! -f "$SCRIPT_DIR/create-vm-node.sh" ]; then
    echo "Error: create-vm-node.sh not found"
    exit 1
fi
chmod +x "$SCRIPT_DIR/create-vm-node.sh"

# Создание всех VM
echo ""
echo "Creating master nodes..."
"$SCRIPT_DIR/create-vm-node.sh" "$master01_Hostname" "$master01_IP" "$master01_Hostname" || exit 1
"$SCRIPT_DIR/create-vm-node.sh" "$master02_Hostname" "$master02_IP" "$master02_Hostname" || exit 1
"$SCRIPT_DIR/create-vm-node.sh" "$master03_Hostname" "$master03_IP" "$master03_Hostname" || exit 1

echo ""
echo "Creating worker nodes..."
"$SCRIPT_DIR/create-vm-node.sh" "$worker01_Hostname" "$worker01_IP" "$worker01_Hostname" || exit 1
"$SCRIPT_DIR/create-vm-node.sh" "$worker02_Hostname" "$worker02_IP" "$worker02_Hostname" || exit 1

echo ""
echo "=========================================="
echo "VM Recreation completed!"
echo "=========================================="
echo ""
echo "VM Status:"
virsh list --all 2>/dev/null || echo "No VMs found"

echo ""
echo "VM IP Addresses:"
for vm in master01 master02 master03 worker01 worker02; do
    if virsh list --all --name | grep -q "^${vm}$"; then
        echo ""
        echo "VM: ${vm}"
        virsh domifaddr "${vm}" 2>/dev/null | grep -E "ipv4|MAC" || echo "  Waiting for IP address..."
    fi
done

echo ""
echo "To check IP addresses manually:"
echo "  virsh domifaddr master01"
echo "  virsh domifaddr master02"
echo "  virsh domifaddr master03"
echo "  virsh domifaddr worker01"
echo "  virsh domifaddr worker02"

