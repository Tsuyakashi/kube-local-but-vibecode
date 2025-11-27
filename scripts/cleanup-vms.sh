#!/bin/bash

# Скрипт для удаления всех VM кластера Kubernetes

set -e
set -o pipefail

# Проверка прав root
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Список VM для удаления
VM_NAMES=("master01" "master02" "master03" "worker01" "worker02" "ubuntu-noble")

echo "=========================================="
echo "Kubernetes Cluster VM Cleanup"
echo "=========================================="
echo ""

# Функция для удаления VM
function removeVM() {
    local VM_NAME="$1"
    
    if ! virsh list --all --name | grep -q "^${VM_NAME}$"; then
        echo "VM ${VM_NAME} does not exist, skipping..."
        return 0
    fi
    
    echo "Removing VM: ${VM_NAME}..."
    
    # Остановка VM если запущена
    if virsh list --name | grep -q "^${VM_NAME}$"; then
        echo "  Stopping VM ${VM_NAME}..."
        virsh shutdown "${VM_NAME}" 2>/dev/null || true
        sleep 3
        
        # Принудительное завершение если не остановилась
        if virsh list --name | grep -q "^${VM_NAME}$"; then
            echo "  Force destroying VM ${VM_NAME}..."
            virsh destroy "${VM_NAME}" 2>/dev/null || true
        fi
    fi
    
    # Удаление VM
    echo "  Undefining VM ${VM_NAME}..."
    virsh undefine "${VM_NAME}" --remove-all-storage 2>/dev/null || {
        # Если не удалось удалить со storage, пробуем без него
        virsh undefine "${VM_NAME}" 2>/dev/null || true
    }
    
    # Удаление образов дисков
    echo "  Removing disk images for ${VM_NAME}..."
    rm -f "/var/lib/libvirt/images/${VM_NAME}-root.img" 2>/dev/null || true
    rm -f "/var/lib/libvirt/images/${VM_NAME}-disk.qcow2" 2>/dev/null || true
    rm -f "/var/lib/libvirt/images/${VM_NAME}-seed.iso" 2>/dev/null || true
    
    echo "  ✓ VM ${VM_NAME} removed"
}

# Удаление всех VM
for VM_NAME in "${VM_NAMES[@]}"; do
    removeVM "$VM_NAME"
    echo ""
done

# Удаление cloud-init конфигураций
echo "Cleaning up cloud-init configurations..."
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SEEDCONFIG_DIR="$PROJECT_ROOT/config/seedconfig"

for VM_NAME in "${VM_NAMES[@]}"; do
    if [ -d "$SEEDCONFIG_DIR/${VM_NAME}" ]; then
        echo "  Removing cloud-init config for ${VM_NAME}..."
        rm -rf "$SEEDCONFIG_DIR/${VM_NAME}" 2>/dev/null || true
    fi
done

echo ""
echo "=========================================="
echo "Cleanup completed!"
echo "=========================================="
echo ""
echo "Remaining VMs:"
virsh list --all 2>/dev/null | grep -E "Id|Name|----" || echo "No VMs found"

