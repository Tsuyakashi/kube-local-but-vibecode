#!/bin/bash

# Скрипт для создания VM узла с заданным именем и IP адресом

set -e
set -o pipefail

if [ $# -lt 3 ]; then
    echo "Usage: $0 <VM_NAME> <VM_IP> <VM_HOSTNAME> [--recreate-iso-only]"
    exit 1
fi

VM_NAME="$1"
VM_IP="$2"
VM_HOSTNAME="$3"
RECREATE_ISO_ONLY="${4:-}"

# Валидация входных параметров
if [ -z "$VM_NAME" ] || [ -z "$VM_IP" ] || [ -z "$VM_HOSTNAME" ]; then
    echo "Error: VM_NAME, VM_IP, and VM_HOSTNAME are required"
    exit 1
fi

# Валидация формата IP адреса
if ! [[ "$VM_IP" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
    echo "Error: Invalid IP address format: $VM_IP"
    exit 1
fi

# Валидация имени VM (только буквы, цифры, дефисы)
if ! [[ "$VM_NAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "Error: Invalid VM name format: $VM_NAME (only alphanumeric and hyphens allowed)"
    exit 1
fi

# Валидация hostname
if ! [[ "$VM_HOSTNAME" =~ ^[a-zA-Z0-9-]+$ ]]; then
    echo "Error: Invalid hostname format: $VM_HOSTNAME (only alphanumeric and hyphens allowed)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
IMAGES_DIR="$PROJECT_ROOT/data/images"
KEYS_DIR="$PROJECT_ROOT/data/keys"
SEEDCONFIG_DIR="$PROJECT_ROOT/config/seedconfig"

# Загрузка переменных для получения VM_PASSWORD
if [ -f "$PROJECT_ROOT/config/variables.sh" ]; then
    source "$PROJECT_ROOT/config/variables.sh"
fi

VM_USER=ubuntu
VM_IMAGE=ubuntu-root.img
VM_IMAGE_FORMAT=img
VM_IMAGE_TEMPLATE=ubuntu-template.img
IMAGE_SIZE=20g
VM_MEMORY=2048
VM_CPUS=2

# Проверка прав root
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Если указан флаг --recreate-iso-only, только пересоздаем cloud-init ISO
if [ "$RECREATE_ISO_ONLY" = "--recreate-iso-only" ]; then
    echo "Recreating cloud-init ISO for ${VM_NAME}..."
    
    # Создание директорий
    mkdir -p "$SEEDCONFIG_DIR"
    
    # Создание cloud-init конфигурации
    VM_SEED_DIR="$SEEDCONFIG_DIR/${VM_NAME}"
    mkdir -p "$VM_SEED_DIR"
    
    # user-data с настройкой сети
    cat > "$VM_SEED_DIR/user-data" <<EOF
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
      
# Настройка сети через DHCP (IP будет зарезервирован в libvirt сети)
# Статический IP будет назначен через DHCP резервацию по MAC адресу
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
        use-routes: true
        use-dns: true
        use-ntp: true
      optional: true
EOF

    # meta-data с hostname
    cat > "$VM_SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_HOSTNAME}
EOF

    # Создание ISO для cloud-init
    if ! genisoimage \
        -output "/var/lib/libvirt/images/${VM_NAME}-seed.iso" \
        -volid cidata \
        -joliet \
        -rock \
        "$VM_SEED_DIR/user-data" \
        "$VM_SEED_DIR/meta-data" &>/dev/null; then
        echo "Error: Failed to create ISO for ${VM_NAME}"
        exit 1
    fi
    
    echo "Cloud-init ISO recreated successfully for ${VM_NAME}"
    exit 0
fi

# Проверка существования VM
if virsh list --all --name | grep -q "^${VM_NAME}$"; then
    echo "VM ${VM_NAME} already exists, skipping creation"
    exit 0
fi

echo "Creating VM node: ${VM_NAME} (${VM_HOSTNAME}) with IP ${VM_IP}"

# Создание директорий
mkdir -p "$IMAGES_DIR"
mkdir -p "$KEYS_DIR"
mkdir -p "$SEEDCONFIG_DIR"

# Генерация SSH ключей (если еще не созданы)
if [ ! -f "$KEYS_DIR/rsa.key" ]; then
    echo "Generating SSH keys..."
    ssh-keygen -f "$KEYS_DIR/rsa.key" -t rsa -N "" > /dev/null
    chmod 600 "$KEYS_DIR/rsa.key"
    chmod 644 "$KEYS_DIR/rsa.key.pub"
fi

# Создание cloud-init конфигурации для конкретной VM
VM_SEED_DIR="$SEEDCONFIG_DIR/${VM_NAME}"
mkdir -p "$VM_SEED_DIR"

# user-data с настройкой статического IP
cat > "$VM_SEED_DIR/user-data" <<EOF
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
      
# Настройка сети через DHCP (IP будет зарезервирован в libvirt сети)
# Статический IP будет назначен через DHCP резервацию по MAC адресу
network:
  version: 2
  ethernets:
    enp1s0:
      dhcp4: true
      dhcp4-overrides:
        route-metric: 100
        use-routes: true
        use-dns: true
        use-ntp: true
      optional: true
EOF

# meta-data с hostname
cat > "$VM_SEED_DIR/meta-data" <<EOF
instance-id: ${VM_NAME}
local-hostname: ${VM_HOSTNAME}
EOF

# Создание ISO для cloud-init
echo "Creating cloud-init ISO for ${VM_NAME}..."
if ! genisoimage \
    -output "/var/lib/libvirt/images/${VM_NAME}-seed.iso" \
    -volid cidata \
    -joliet \
    -rock \
    "$VM_SEED_DIR/user-data" \
    "$VM_SEED_DIR/meta-data" &>/dev/null; then
    echo "Error: Failed to create ISO for ${VM_NAME}"
    exit 1
fi

# Проверка наличия базового образа Ubuntu
if [ ! -f "/var/lib/libvirt/images/${VM_IMAGE}" ]; then
    echo "Error: Ubuntu base image not found at /var/lib/libvirt/images/${VM_IMAGE}"
    echo "Please run kvm-install.sh first to download the image"
    exit 1
fi

# Создание отдельной копии образа для этой VM (чтобы избежать конфликтов)
# Используем полную копию вместо клона, чтобы избежать проблем с блокировками backing file
VM_IMAGE_COPY="${VM_NAME}-root.img"
if [ ! -f "/var/lib/libvirt/images/$VM_IMAGE_COPY" ]; then
    echo "Creating full image copy for ${VM_NAME} (this may take a few minutes)..."
    if ! qemu-img convert -f qcow2 -O qcow2 "/var/lib/libvirt/images/${VM_IMAGE}" "/var/lib/libvirt/images/$VM_IMAGE_COPY" 2>&1; then
        echo "Error: Failed to create image copy for ${VM_NAME}"
        exit 1
    fi
    echo "Image copy created successfully"
else
    echo "Image copy for ${VM_NAME} already exists"
fi

# Создание дополнительного диска
DISK_NAME="${VM_NAME}-disk.qcow2"
if [ ! -f "/var/lib/libvirt/images/$DISK_NAME" ]; then
    echo "Creating additional disk for ${VM_NAME}..."
    qemu-img create -f qcow2 "/var/lib/libvirt/images/$DISK_NAME" 25G &>/dev/null
fi

# Определение MAC адреса для резервации IP на основе имени узла
# Формат: master01 -> 52:54:00:44:44:11, master02 -> 52:54:00:44:44:12, ...
#         worker01 -> 52:54:00:44:44:21, worker02 -> 52:54:00:44:44:22, ...
if [[ "$VM_NAME" =~ ^(master|worker)([0-9]+)$ ]]; then
    NODE_TYPE="${BASH_REMATCH[1]}"
    NODE_INDEX="${BASH_REMATCH[2]}"
    
    # Убираем ведущие нули из индекса
    NODE_INDEX=$((10#$NODE_INDEX))
    
    if [ "$NODE_TYPE" = "master" ]; then
        # Мастера: 52:54:00:44:44:11, 52:54:00:44:44:12, ...
        OCTET=$((10 + NODE_INDEX))
        VM_MAC=$(printf "52:54:00:44:44:%02x" "$OCTET")
    else
        # Воркеры: 52:54:00:44:44:21, 52:54:00:44:44:22, ...
        OCTET=$((20 + NODE_INDEX))
        VM_MAC=$(printf "52:54:00:44:44:%02x" "$OCTET")
    fi
else
    # Для узлов с нестандартными именами генерируем случайный MAC
    echo "Warning: VM name ${VM_NAME} doesn't match expected pattern (masterXX/workerXX)"
    echo "Generating random MAC address..."
    VM_MAC="52:54:00:$(openssl rand -hex 3 | sed 's/\(..\)\(..\)\(..\)/\1:\2:\3/')"
fi

# Создание VM
echo "Creating VM ${VM_NAME} with MAC ${VM_MAC}..."
if ! virt-install \
    --name "$VM_NAME" \
    --memory "$VM_MEMORY" \
    --vcpus "$VM_CPUS" \
    --disk "path=/var/lib/libvirt/images/$VM_IMAGE_COPY,format=qcow2" \
    --disk "path=/var/lib/libvirt/images/${VM_NAME}-seed.iso,device=cdrom" \
    --disk "path=/var/lib/libvirt/images/$DISK_NAME,format=qcow2" \
    --network network=k8s-cluster,mac="${VM_MAC}" \
    --os-variant ubuntu22.04 \
    --virt-type kvm \
    --graphics none \
    --console pty,target_type=serial \
    --noautoconsole \
    --import 2>&1; then
    echo "Error: Failed to create VM ${VM_NAME}"
    echo "Checking if VM already exists..."
    if virsh list --all --name | grep -q "^${VM_NAME}$"; then
        echo "VM ${VM_NAME} already exists, continuing..."
    else
        echo "VM creation failed. Check libvirt logs: journalctl -u libvirtd"
        exit 1
    fi
fi

echo "VM ${VM_NAME} created successfully"
echo "Waiting for VM to start and get IP address..."

# Ожидание получения IP адреса
max_attempts=60
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; then
        ACTUAL_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
        echo "VM ${VM_NAME} is running on ${ACTUAL_IP}"
        
        # Проверка SSH доступности
        if nc -z "$ACTUAL_IP" 22 2>/dev/null; then
            echo "SSH is accessible on ${VM_NAME}"
            exit 0
        fi
    fi
    attempt=$((attempt + 1))
    sleep 2
    if [ $((attempt % 10)) -eq 0 ]; then
        echo "Still waiting for ${VM_NAME}... (attempt $attempt/$max_attempts)"
    fi
done

echo "Warning: VM ${VM_NAME} did not become fully accessible in time"
echo "You may need to check it manually: virsh console ${VM_NAME}"
exit 1

