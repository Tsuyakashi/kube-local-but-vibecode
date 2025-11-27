#!/bin/bash

set -e
set -o pipefail

# Configuration variables
VM_NAME=ubuntu-noble
VM_IP=""
APT_UPDATED=0

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "Error: You need to run this script as root"
		exit 1
	fi
}

function getUbuntuVm() {
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    
    if [ ! -f "$SCRIPT_DIR/kvm-install.sh" ]; then
        echo "Error: kvm-install.sh not found"
        exit 1
    fi
    
    chmod +x "$SCRIPT_DIR/kvm-install.sh"
    
    # Проверяем, существует ли VM
    if ! virsh list --all --name | grep -q "^${VM_NAME}$"; then
        echo "Creating new VM: ${VM_NAME}"
        cd "$PROJECT_ROOT" && "$SCRIPT_DIR/kvm-install.sh" --full
    else
        echo "VM ${VM_NAME} already exists"
        
        # Проверяем, запущена ли VM
        if ! virsh list --name | grep -q "^${VM_NAME}$"; then
            echo "Starting VM ${VM_NAME}..."
            virsh start "${VM_NAME}"
            
            # Ждем запуска VM
            local max_attempts=30
            local attempt=0
            while ! virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; do
                attempt=$((attempt + 1))
                if [ $attempt -ge $max_attempts ]; then
                    echo "Error: VM did not start in time"
                    exit 1
                fi
                sleep 2
            done
            echo "VM ${VM_NAME} started"
        else
            echo "VM ${VM_NAME} is already running"
        fi
    fi
}


function connectWithSSH() {
    local SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
    local max_attempts=30
    local attempt=0
    
    # Проверка наличия необходимых утилит
    if ! command -v nc &>/dev/null && ! command -v netcat &>/dev/null; then
        echo "Installing netcat..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        apt install -y netcat-openbsd &>/dev/null
    fi
    
    if ! virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; then
        echo "Error: VM ${VM_NAME} did not start or is not accessible"
        exit 1
    fi
    
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
    if [ -z "$VM_IP" ]; then
        echo "Error: Could not determine VM IP address"
        exit 1
    fi
    
    echo "Waiting for VM to be accessible on port 22..."
    local nc_cmd="nc"
    if ! command -v nc &>/dev/null; then
        nc_cmd="netcat"
    fi
    
    while ! $nc_cmd -z "$VM_IP" 22 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "Error: VM did not become accessible after $max_attempts attempts"
            exit 1
        fi
        sleep 5
        echo "Waiting for VM to be accessible... (attempt $attempt/$max_attempts)"
    done
    echo "VM is accessible at ${VM_IP}"

    if [ ! -f "$PROJECT_ROOT/data/keys/rsa.key" ]; then
        echo "Error: SSH key not found at $PROJECT_ROOT/data/keys/rsa.key"
        exit 1
    fi
    
    chmod 600 "$PROJECT_ROOT/data/keys/rsa.key"
    if [ -n "$SUDO_USER" ] && [ "${EUID}" -eq 0 ]; then
        chown "$SUDO_USER:$SUDO_USER" "$PROJECT_ROOT/data/keys/rsa.key"
        [ -f "$PROJECT_ROOT/data/keys/rsa.key.pub" ] && chown "$SUDO_USER:$SUDO_USER" "$PROJECT_ROOT/data/keys/rsa.key.pub"
    fi
    
    echo "Copying files to VM..."
    
    # Копирование основного скрипта установки Kubernetes
    if [ ! -f "$SCRIPT_DIR/install-kubernetes.sh" ]; then
        echo "Error: install-kubernetes.sh not found"
        exit 1
    fi
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "$SCRIPT_DIR/install-kubernetes.sh" \
        "ubuntu@${VM_IP}:~/" || {
        echo "Error: Failed to copy install-kubernetes.sh"
        exit 1
    }

    # Копирование variables.sh
    if [ -f "$PROJECT_ROOT/config/variables.sh" ]; then
        scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            "$PROJECT_ROOT/config/variables.sh" \
            "ubuntu@${VM_IP}:~/" || {
            echo "Warning: Failed to copy variables.sh"
        }
    else
        echo "Error: variables.sh not found"
        exit 1
    fi

    # Копирование fix-boot.sh (опционально)
    if [ -f "$SCRIPT_DIR/fix-boot.sh" ]; then
        scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            "$SCRIPT_DIR/fix-boot.sh" \
            "ubuntu@${VM_IP}:~/" || {
            echo "Warning: Failed to copy fix-boot.sh"
        }
    fi

    echo "Executing Kubernetes installation script on VM..."
    echo "Note: This may take 10-20 minutes. Please be patient..."
    ssh -t -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=30 \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=10 \
        -o TCPKeepAlive=yes \
        "ubuntu@${VM_IP}" \
        "chmod +x ./install-kubernetes.sh && sudo -E bash ./install-kubernetes.sh 2>&1 | tee /tmp/k8s-install.log" || {
        echo "Error: Failed to execute installation script on VM"
        echo "Checking installation log..."
        ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            "ubuntu@${VM_IP}" \
            "tail -50 /tmp/k8s-install.log 2>/dev/null || echo 'Log file not found'" || true
        exit 1
    }
    
    # Копирование kubeconfig на хост для доступа извне
    echo ""
    echo "Copying kubeconfig to host for external access..."
    mkdir -p "$PROJECT_ROOT/data/kubeconfig"
    
    # Ждем немного, чтобы убедиться что kubeconfig создан
    sleep 2
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "ubuntu@${VM_IP}:/home/ubuntu/.kube/config" \
        "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || {
        echo "Warning: Failed to copy kubeconfig from VM"
        echo "You can copy it manually:"
        echo "  scp -i data/keys/rsa.key ubuntu@${VM_IP}:~/.kube/config data/kubeconfig/config"
    }
    
    if [ -f "$PROJECT_ROOT/data/kubeconfig/config" ]; then
        # Обновляем IP адрес в kubeconfig для доступа с хоста
        # Заменяем localhost/127.0.0.1 на реальный IP VM
        if [ -n "$VM_IP" ]; then
            sed -i.bak "s|server: https://127.0.0.1:6443|server: https://${VM_IP}:6443|g" "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || true
            sed -i.bak "s|server: https://localhost:6443|server: https://${VM_IP}:6443|g" "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || true
            rm -f "$PROJECT_ROOT/data/kubeconfig/config.bak" 2>/dev/null || true
        fi
        
        echo "✓ kubeconfig copied to $PROJECT_ROOT/data/kubeconfig/config"
        echo ""
        echo "To use kubectl from host:"
        echo "  export KUBECONFIG=$PROJECT_ROOT/data/kubeconfig/config"
        echo "  kubectl get nodes"
        echo ""
        echo "Or copy to default location:"
        echo "  mkdir -p ~/.kube"
        echo "  cp $PROJECT_ROOT/data/kubeconfig/config ~/.kube/config"
    fi
}

# Main execution
isRoot

echo "Running in host mode: Setting up Ubuntu VM and connecting via SSH"
getUbuntuVm
connectWithSSH