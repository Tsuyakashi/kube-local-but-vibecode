#!/bin/bash
# Скрипт для исправления Calico CNI на VM
# Запускается на хосте

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$SCRIPT_DIR"
VM_NAME="ubuntu-noble"

function get_vm_ip() {
    if ! virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; then
        echo "Error: VM ${VM_NAME} is not running"
        exit 1
    fi
    
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
    if [ -z "$VM_IP" ]; then
        echo "Error: Could not determine VM IP address"
        exit 1
    fi
    echo "$VM_IP"
}

VM_IP=$(get_vm_ip)
echo "VM IP: ${VM_IP}"

if [ ! -f "$PROJECT_ROOT/data/keys/rsa.key" ]; then
    echo "Error: SSH key not found at $PROJECT_ROOT/data/keys/rsa.key"
    exit 1
fi

echo "Copying fix-calico.sh to VM..."
scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "$PROJECT_ROOT/scripts/fix-calico.sh" \
    "ubuntu@${VM_IP}:~/" || {
    echo "Error: Failed to copy fix-calico.sh"
    exit 1
}

if [ -f "$PROJECT_ROOT/config/variables.sh" ]; then
    echo "Copying variables.sh to VM..."
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "$PROJECT_ROOT/config/variables.sh" \
        "ubuntu@${VM_IP}:~/" || {
        echo "Warning: Failed to copy variables.sh"
    }
fi

echo "Executing fix-calico.sh on VM..."
ssh -t -i "$PROJECT_ROOT/data/keys/rsa.key" \
    -o StrictHostKeyChecking=accept-new \
    -o ConnectTimeout=10 \
    "ubuntu@${VM_IP}" \
    "chmod +x ./fix-calico.sh && sudo ./fix-calico.sh"

