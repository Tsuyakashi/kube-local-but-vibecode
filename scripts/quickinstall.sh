#!/bin/bash

set -e
set -o pipefail

# Configuration variables
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Load variables from config/variables.sh
if [ ! -f "$PROJECT_ROOT/config/variables.sh" ]; then
    echo "Error: variables.sh not found"
    exit 1
fi
source "$PROJECT_ROOT/config/variables.sh"

APT_UPDATED=0

# Default parameters
NUM_MASTERS=3
NUM_WORKERS=2

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --masters)
            NUM_MASTERS="$2"
            shift 2
            ;;
        --workers)
            NUM_WORKERS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--masters N] [--workers N]"
            echo ""
            echo "Options:"
            echo "  --masters N    Number of master nodes (default: 3)"
            echo "  --workers N    Number of worker nodes (default: 2)"
            echo ""
            echo "Examples:"
            echo "  $0                    # 3 masters, 2 workers (default)"
            echo "  $0 --masters 1        # 1 master, 2 workers"
            echo "  $0 --masters 5 --workers 3  # 5 masters, 3 workers"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Validate parameters
if ! [[ "$NUM_MASTERS" =~ ^[0-9]+$ ]] || [ "$NUM_MASTERS" -lt 1 ]; then
    echo "Error: --masters must be a positive integer"
    exit 1
fi

if ! [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] || [ "$NUM_WORKERS" -lt 0 ]; then
    echo "Error: --workers must be a non-negative integer"
    exit 1
fi

# Arrays to store node information
declare -a MASTER_NAMES
declare -a MASTER_IPS
declare -a MASTER_HOSTNAMES
declare -a WORKER_NAMES
declare -a WORKER_IPS
declare -a WORKER_HOSTNAMES

# Function to generate MAC address
function generateMAC() {
    local NODE_TYPE="$1"  # "master" or "worker"
    local INDEX="$2"      # node number (1-based)
    
    if [ "$NODE_TYPE" = "master" ]; then
        # Masters: 52:54:00:44:44:11, 52:54:00:44:44:12, ...
        local OCTET=$((10 + INDEX))
        printf "52:54:00:44:44:%02x" "$OCTET"
    else
        # Workers: 52:54:00:44:44:21, 52:54:00:44:44:22, ...
        local OCTET=$((20 + INDEX))
        printf "52:54:00:44:44:%02x" "$OCTET"
    fi
}

# Function to generate IP address
function generateIP() {
    local NODE_TYPE="$1"  # "master" or "worker"
    local INDEX="$2"      # node number (1-based)
    
    if [ "$NODE_TYPE" = "master" ]; then
        # Masters: 10.44.44.11, 10.44.44.12, ...
        echo "10.44.44.$((10 + INDEX))"
    else
        # Workers: 10.44.44.21, 10.44.44.22, ...
        echo "10.44.44.$((20 + INDEX))"
    fi
}

# Function to generate hostname
function generateHostname() {
    local NODE_TYPE="$1"  # "master" or "worker"
    local INDEX="$2"      # node number (1-based)
    
    printf "%s%02d" "$NODE_TYPE" "$INDEX"
}

# Initialize node arrays
function initializeNodes() {
    # Generate masters
    for i in $(seq 1 "$NUM_MASTERS"); do
        MASTER_NAMES[$((i-1))]=$(generateHostname "master" "$i")
        MASTER_IPS[$((i-1))]=$(generateIP "master" "$i")
        MASTER_HOSTNAMES[$((i-1))]=$(generateHostname "master" "$i")
    done
    
    # Generate workers
    for i in $(seq 1 "$NUM_WORKERS"); do
        WORKER_NAMES[$((i-1))]=$(generateHostname "worker" "$i")
        WORKER_IPS[$((i-1))]=$(generateIP "worker" "$i")
        WORKER_HOSTNAMES[$((i-1))]=$(generateHostname "worker" "$i")
    done
    
    # Set master01_IP for backward compatibility
    if [ "$NUM_MASTERS" -ge 1 ]; then
        master01_IP="${MASTER_IPS[0]}"
        master01_Hostname="${MASTER_HOSTNAMES[0]}"
    fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "Error: You need to run this script as root"
		exit 1
	fi
}

# Function to create VM node
function createVMNode() {
    local NODE_NAME="$1"
    local NODE_IP="$2"
    local NODE_HOSTNAME="$3"
    
    echo ""
    echo "=========================================="
    echo "Creating VM node: ${NODE_NAME}"
    echo "  IP: ${NODE_IP}"
    echo "  Hostname: ${NODE_HOSTNAME}"
    echo "=========================================="
    
    # Check if VM exists
    if virsh list --all --name | grep -q "^${NODE_NAME}$"; then
        echo "VM ${NODE_NAME} already exists"
        
        # Check if VM has IP address
        local has_ip=false
        if virsh list --name | grep -q "^${NODE_NAME}$"; then
            # VM is running, check IP
            if virsh domifaddr "$NODE_NAME" 2>/dev/null | grep -q "ipv4"; then
                has_ip=true
            elif [ -n "$NODE_IP" ] && nc -z "$NODE_IP" 22 2>/dev/null; then
                has_ip=true
            fi
        fi
        
        # If VM is running but has no IP, restart and recreate cloud-init ISO
        if [ "$has_ip" = false ] && virsh list --name | grep -q "^${NODE_NAME}$"; then
            echo "VM ${NODE_NAME} is running but has no IP."
            echo "Recreating cloud-init ISO and restarting VM..."
            
            # Recreate cloud-init ISO
            if [ -f "$SCRIPT_DIR/create-vm-node.sh" ]; then
                chmod +x "$SCRIPT_DIR/create-vm-node.sh"
                # Recreate only cloud-init ISO (VM already exists)
                "$SCRIPT_DIR/create-vm-node.sh" "$NODE_NAME" "$NODE_IP" "$NODE_HOSTNAME" --recreate-iso-only 2>/dev/null || {
                    echo "Warning: Failed to recreate cloud-init ISO, trying regular restart..."
                }
            fi
            
            virsh shutdown "${NODE_NAME}" 2>/dev/null || true
            sleep 5  # Give time for proper shutdown
            virsh start "${NODE_NAME}"
            echo "Waiting for VM ${NODE_NAME} to boot and get IP address..."
            sleep 20  # Increased wait time after restart (cloud-init needs time)
        fi
        
        # Start VM if not running
        if ! virsh list --name | grep -q "^${NODE_NAME}$"; then
            echo "Starting VM ${NODE_NAME}..."
            virsh start "${NODE_NAME}"
            sleep 5  # Give time for boot
        fi
        
        echo "VM ${NODE_NAME} is ready"
        return 0
    fi
    
    # Create VM via create-vm-node.sh
    if [ ! -f "$SCRIPT_DIR/create-vm-node.sh" ]; then
        echo "Error: create-vm-node.sh not found"
        exit 1
    fi
    
    chmod +x "$SCRIPT_DIR/create-vm-node.sh"
    "$SCRIPT_DIR/create-vm-node.sh" "$NODE_NAME" "$NODE_IP" "$NODE_HOSTNAME" || {
        echo "Error: Failed to create VM ${NODE_NAME}"
        return 1
    }
}

# Function to install Kubernetes on node
function installKubernetesOnNode() {
    local NODE_NAME="$1"
    local EXPECTED_IP="$2"
    
    echo ""
    echo "=========================================="
    echo "Installing Kubernetes on ${NODE_NAME} (expected IP: ${EXPECTED_IP})"
    echo "=========================================="
    
    # Get real IP address of VM
    local NODE_IP=""
    local max_attempts=30  # Reduced from 60 to 30 (1 minute instead of 2)
    local attempt=0
    
    echo "Waiting for VM ${NODE_NAME} to get IP address..."
    
    # First check if VM is running
    if ! virsh list --name | grep -q "^${NODE_NAME}$"; then
        echo "VM ${NODE_NAME} is not running. Starting it..."
        virsh start "${NODE_NAME}" 2>/dev/null || {
            echo "Error: Failed to start VM ${NODE_NAME}"
            return 1
        }
        sleep 3
    fi
    
    # Quick check via expected IP (if known)
    if [ -n "$EXPECTED_IP" ]; then
        echo "Checking expected IP ${EXPECTED_IP}..."
        for quick_check in $(seq 1 5); do
            if nc -z "$EXPECTED_IP" 22 2>/dev/null; then
                NODE_IP="$EXPECTED_IP"
                echo "VM ${NODE_NAME} is accessible on expected IP: ${NODE_IP}"
                break
            fi
            sleep 1
        done
    fi
    
    # If didn't get IP via expected, try via virsh
    if [ -z "$NODE_IP" ]; then
        while [ $attempt -lt $max_attempts ]; do
            # Try to get IP from virsh domifaddr
            local virsh_output=$(virsh domifaddr "$NODE_NAME" 2>/dev/null)
            if echo "$virsh_output" | grep -q "ipv4"; then
                NODE_IP=$(echo "$virsh_output" | awk '/ipv4/ { split($4, a, "/"); print a[1] }' | head -1)
                if [ -n "$NODE_IP" ] && [ "$NODE_IP" != "" ]; then
                    echo "VM ${NODE_NAME} has IP: ${NODE_IP}"
                    break
                fi
            fi
            
            # Alternative method - via SSH if expected IP is known
            if [ -n "$EXPECTED_IP" ] && nc -z "$EXPECTED_IP" 22 2>/dev/null; then
                NODE_IP="$EXPECTED_IP"
                echo "VM ${NODE_NAME} is accessible on expected IP: ${NODE_IP}"
                break
            fi
            
            attempt=$((attempt + 1))
            if [ $((attempt % 3)) -eq 0 ]; then
                echo "Still waiting for ${NODE_NAME}... (attempt $attempt/$max_attempts)"
                # Show current status
                local vm_status=$(virsh domifaddr "$NODE_NAME" 2>/dev/null || echo "  No IP address yet")
                echo "  Status: $vm_status"
            fi
            sleep 2
        done
    fi
    
    # If failed to determine IP, use expected IP as fallback
    if [ -z "$NODE_IP" ]; then
        if [ -n "$EXPECTED_IP" ]; then
            echo "Warning: Could not determine IP from virsh, using expected IP: ${EXPECTED_IP}"
            echo "Checking if VM is accessible on expected IP..."
            if nc -z "$EXPECTED_IP" 22 2>/dev/null; then
                NODE_IP="$EXPECTED_IP"
                echo "VM ${NODE_NAME} is accessible on expected IP: ${NODE_IP}"
            else
                echo "Error: Could not determine IP address for ${NODE_NAME}"
                echo "VM status:"
                virsh dominfo "$NODE_NAME" 2>/dev/null | grep -E "State|Autostart" || true
                echo "Network interfaces:"
                virsh domifaddr "$NODE_NAME" 2>/dev/null || echo "  No interfaces found"
                echo "Expected IP ${EXPECTED_IP} is not accessible"
                return 1
            fi
        else
            echo "Error: Could not determine IP address for ${NODE_NAME}"
            echo "VM status:"
            virsh dominfo "$NODE_NAME" 2>/dev/null | grep -E "State|Autostart" || true
            echo "Network interfaces:"
            virsh domifaddr "$NODE_NAME" 2>/dev/null || echo "  No interfaces found"
            return 1
        fi
    fi
    
    # Remove old SSH keys for this IP (if VM was recreated)
    ssh-keygen -R "${NODE_IP}" -f /root/.ssh/known_hosts 2>/dev/null || true
    ssh-keygen -R "${NODE_NAME}" -f /root/.ssh/known_hosts 2>/dev/null || true
    
    # Check SSH accessibility
    echo "Checking SSH connectivity to ${NODE_NAME} (${NODE_IP})..."
    if ! nc -z "$NODE_IP" 22 2>/dev/null; then
        echo "Error: Cannot connect to ${NODE_NAME} via SSH on ${NODE_IP}"
        return 1
    fi
    
    echo "SSH is accessible on ${NODE_NAME} (${NODE_IP})"
    
    # Copy files
    echo "Copying installation files to ${NODE_NAME}..."
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "$SCRIPT_DIR/install-kubernetes.sh" \
        "ubuntu@${NODE_IP}:~/" || {
        echo "Error: Failed to copy install-kubernetes.sh"
        return 1
    }
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "$PROJECT_ROOT/config/variables.sh" \
        "ubuntu@${NODE_IP}:~/" || {
        echo "Error: Failed to copy variables.sh"
        return 1
    }
    
    # Install Kubernetes
    echo "Installing Kubernetes on ${NODE_NAME}..."
    echo "Note: This may take 10-20 minutes. Please be patient..."
    
    ssh -t -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        -o ServerAliveInterval=60 \
        -o ServerAliveCountMax=10 \
        -o TCPKeepAlive=yes \
        "ubuntu@${NODE_IP}" \
        "chmod +x ./install-kubernetes.sh && sudo -E bash ./install-kubernetes.sh 2>&1 | tee /tmp/k8s-install.log" || {
        echo "Error: Failed to execute installation script on ${NODE_NAME}"
        echo "Checking installation log..."
        ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "ubuntu@${NODE_IP}" \
            "tail -50 /tmp/k8s-install.log 2>/dev/null || echo 'Log file not found'" || true
        return 1
    }
    
    echo "✓ Kubernetes installed successfully on ${NODE_NAME}"
}

# Function to get join token from first master
function getJoinToken() {
    local MASTER_IP="$1"
    
    echo "Getting join token from master01 (${MASTER_IP})..."
    
    # Wait until cluster is ready
    local max_attempts=60
    local attempt=0
    while [ $attempt -lt $max_attempts ]; do
        if ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "ubuntu@${MASTER_IP}" \
            "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes 2>/dev/null" | grep -q "Ready"; then
            echo "Cluster is ready"
            break
        fi
        attempt=$((attempt + 1))
        sleep 5
        if [ $((attempt % 10)) -eq 0 ]; then
            echo "Waiting for cluster to be ready... (attempt $attempt/$max_attempts)"
        fi
    done
    
    # Get token (create new if needed)
    echo "Creating/retrieving join token..."
    KUBEADM_TOKEN=$(ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "ubuntu@${MASTER_IP}" \
        "sudo kubeadm token create --ttl=0 --print-join-command 2>/dev/null | awk '{print \$5}'" || echo "")
    
    # If failed to get token, try to get existing non-expired one
    if [ -z "$KUBEADM_TOKEN" ]; then
        echo "Trying to get existing non-expired token..."
        KUBEADM_TOKEN=$(ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "ubuntu@${MASTER_IP}" \
            "sudo kubeadm token list 2>/dev/null | grep -v '^TOKEN' | awk '\$2 == \"never\" || \$2 !~ /expired/ {print \$1}' | head -1" || echo "")
    fi
    
    # Get CA cert hash
    echo "Getting CA certificate hash..."
    KUBEADM_CA_CERT_HASH=$(ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "ubuntu@${MASTER_IP}" \
        "openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt 2>/dev/null | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'" || echo "")
    
    if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_CA_CERT_HASH" ]; then
        echo "Error: Failed to get join token from master"
        echo "Token: ${KUBEADM_TOKEN:-(empty)}"
        echo "Hash: ${KUBEADM_CA_CERT_HASH:-(empty)}"
        return 1
    fi
    
    echo "Join token obtained successfully"
    echo "Token: ${KUBEADM_TOKEN:0:10}... (truncated)"
    echo "CA Hash: ${KUBEADM_CA_CERT_HASH:0:20}... (truncated)"
    export KUBEADM_TOKEN
    export KUBEADM_CA_CERT_HASH
}

# Function to join master to cluster
function joinMasterNode() {
    local NODE_NAME="$1"
    local NODE_IP="$2"
    
    echo ""
    echo "=========================================="
    echo "Joining master node: ${NODE_NAME} (${NODE_IP})"
    echo "=========================================="
    
    # Copy certificates from first master
    local FIRST_MASTER_IP="${MASTER_IPS[0]}"
    echo "Copying certificates from ${MASTER_HOSTNAMES[0]}..."
    
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "ubuntu@${FIRST_MASTER_IP}" \
        "sudo tar -czf /tmp/etcd-certs.tar.gz -C /etc/kubernetes/pki etcd/ca.crt etcd/ca.key etcd/server.crt etcd/server.key etcd/peer.crt etcd/peer.key 2>/dev/null" || {
        echo "Warning: Failed to create certificates archive"
    }
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        "ubuntu@${FIRST_MASTER_IP}:/tmp/etcd-certs.tar.gz" \
        "/tmp/etcd-certs.tar.gz" 2>/dev/null || {
        echo "Warning: Failed to copy certificates"
    }
    
    if [ -f "/tmp/etcd-certs.tar.gz" ]; then
        scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            "/tmp/etcd-certs.tar.gz" \
            "ubuntu@${NODE_IP}:/tmp/" || {
            echo "Warning: Failed to copy certificates to ${NODE_NAME}"
        }
        
        ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            "ubuntu@${NODE_IP}" \
            "sudo mkdir -p /etc/kubernetes/pki/etcd && sudo tar -xzf /tmp/etcd-certs.tar.gz -C /etc/kubernetes/pki/etcd && sudo chown root:root /etc/kubernetes/pki/etcd/*" || {
            echo "Warning: Failed to extract certificates on ${NODE_NAME}"
        }
    fi
    
    # Join master
    local FIRST_MASTER_IP="${MASTER_IPS[0]}"
    echo "Joining ${NODE_NAME} as control-plane node..."
    
    # Clean up previous installation attempts (if any)
    echo "Cleaning up any previous Kubernetes installation on ${NODE_NAME}..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        "ubuntu@${NODE_IP}" \
        "sudo kubeadm reset -f 2>/dev/null || true; \
         sudo rm -rf /etc/kubernetes/* 2>/dev/null || true; \
         sudo rm -rf /var/lib/etcd/* 2>/dev/null || true; \
         sudo systemctl stop kubelet 2>/dev/null || true; \
         sudo systemctl stop containerd 2>/dev/null || true; \
         sudo systemctl start containerd 2>/dev/null || true" || true
    
    ssh -t -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        "ubuntu@${NODE_IP}" \
        "sudo KUBEADM_TOKEN='${KUBEADM_TOKEN}' KUBEADM_CA_CERT_HASH='${KUBEADM_CA_CERT_HASH}' kubeadm join ${FIRST_MASTER_IP}:6443 --token '${KUBEADM_TOKEN}' --discovery-token-ca-cert-hash sha256:'${KUBEADM_CA_CERT_HASH}' --control-plane" || {
        echo "Error: Failed to join ${NODE_NAME} as control-plane"
        return 1
    }
    
    echo "✓ Master node ${NODE_NAME} joined successfully"
}

# Function to join worker to cluster
function joinWorkerNode() {
    local NODE_NAME="$1"
    local NODE_IP="$2"
    
    echo ""
    echo "=========================================="
    echo "Joining worker node: ${NODE_NAME} (${NODE_IP})"
    echo "=========================================="
    
    local FIRST_MASTER_IP="${MASTER_IPS[0]}"
    
    # Check if token and hash exist
    if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_CA_CERT_HASH" ]; then
        echo "Error: KUBEADM_TOKEN or KUBEADM_CA_CERT_HASH is not set"
        echo "Re-obtaining join token from ${FIRST_MASTER_IP}..."
        getJoinToken "${FIRST_MASTER_IP}" || {
            echo "Error: Failed to get join token"
            return 1
        }
    fi
    
    # Check master accessibility
    echo "Checking master node accessibility (${FIRST_MASTER_IP}:6443)..."
    if ! nc -z "${FIRST_MASTER_IP}" 6443 2>/dev/null; then
        echo "Warning: Cannot reach master node on ${FIRST_MASTER_IP}:6443"
        echo "Waiting 10 seconds and retrying..."
        sleep 10
        if ! nc -z "${FIRST_MASTER_IP}" 6443 2>/dev/null; then
            echo "Error: Master node ${FIRST_MASTER_IP}:6443 is not accessible"
            return 1
        fi
    fi
    echo "Master node is accessible"
    
    # Check SSH accessibility of worker
    echo "Checking SSH connectivity to ${NODE_NAME} (${NODE_IP})..."
    ssh-keygen -R "${NODE_IP}" -f /root/.ssh/known_hosts 2>/dev/null || true
    if ! nc -z "$NODE_IP" 22 2>/dev/null; then
        echo "Error: Cannot connect to ${NODE_NAME} via SSH on ${NODE_IP}"
        return 1
    fi
    echo "SSH is accessible"
    
    echo "Joining ${NODE_NAME} as worker node..."
    echo "Using token: ${KUBEADM_TOKEN:0:10}... (truncated)"
    echo "Using master: ${FIRST_MASTER_IP}:6443"
    
    # Clean up previous installation attempts (if any)
    echo "Cleaning up any previous Kubernetes installation on ${NODE_NAME}..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        "ubuntu@${NODE_IP}" \
        "sudo kubeadm reset -f 2>/dev/null || true; \
         sudo rm -rf /etc/kubernetes/* 2>/dev/null || true; \
         sudo rm -rf /var/lib/etcd/* 2>/dev/null || true; \
         sudo systemctl stop kubelet 2>/dev/null || true; \
         sudo systemctl stop containerd 2>/dev/null || true; \
         sudo systemctl start containerd 2>/dev/null || true" || true
    
    # Join worker with detailed logging
    if ! ssh -t -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=30 \
        "ubuntu@${NODE_IP}" \
        "sudo KUBEADM_TOKEN='${KUBEADM_TOKEN}' KUBEADM_CA_CERT_HASH='${KUBEADM_CA_CERT_HASH}' kubeadm join ${FIRST_MASTER_IP}:6443 --token '${KUBEADM_TOKEN}' --discovery-token-ca-cert-hash sha256:'${KUBEADM_CA_CERT_HASH}' --v=5 2>&1 | tee /tmp/kubeadm-join.log"; then
        echo "Error: Failed to join ${NODE_NAME} as worker"
        echo "Checking join log on ${NODE_NAME}..."
        ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
            -o StrictHostKeyChecking=accept-new \
            -o UserKnownHostsFile=/dev/null \
            -o ConnectTimeout=10 \
            "ubuntu@${NODE_IP}" \
            "tail -50 /tmp/kubeadm-join.log 2>/dev/null || echo 'Log file not found'" || true
        return 1
    fi
    
    echo "✓ Worker node ${NODE_NAME} joined successfully"
    
    # Check node status after a few seconds
    sleep 5
    echo "Verifying node status..."
    if ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "ubuntu@${FIRST_MASTER_IP}" \
        "sudo kubectl --kubeconfig=/etc/kubernetes/admin.conf get nodes ${NODE_NAME} 2>/dev/null" | grep -q "${NODE_NAME}"; then
        echo "✓ Node ${NODE_NAME} is visible in cluster"
    else
        echo "Warning: Node ${NODE_NAME} is not yet visible in cluster (may need more time)"
    fi
}

# Function to copy kubeconfig to host
function copyKubeconfigToHost() {
    local FIRST_MASTER_IP="${MASTER_IPS[0]}"
    
    echo ""
    echo "Copying kubeconfig to host for external access..."
    mkdir -p "$PROJECT_ROOT/data/kubeconfig"
    
    sleep 2
    
    scp -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o UserKnownHostsFile=/dev/null \
        -o ConnectTimeout=10 \
        "ubuntu@${FIRST_MASTER_IP}:/home/ubuntu/.kube/config" \
        "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || {
        echo "Warning: Failed to copy kubeconfig from VM"
        return 1
    }
    
    if [ -f "$PROJECT_ROOT/data/kubeconfig/config" ]; then
        # Update IP address in kubeconfig for host access
        # Use first master
        if [ -n "$FIRST_MASTER_IP" ]; then
            sed -i.bak "s|server: https://127.0.0.1:6443|server: https://${FIRST_MASTER_IP}:6443|g" "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || true
            sed -i.bak "s|server: https://localhost:6443|server: https://${FIRST_MASTER_IP}:6443|g" "$PROJECT_ROOT/data/kubeconfig/config" 2>/dev/null || true
            rm -f "$PROJECT_ROOT/data/kubeconfig/config.bak" 2>/dev/null || true
        fi
        
        echo "✓ kubeconfig copied to $PROJECT_ROOT/data/kubeconfig/config"
        echo ""
        echo "To use kubectl from host:"
        echo "  export KUBECONFIG=$PROJECT_ROOT/data/kubeconfig/config"
        echo "  kubectl get nodes"
    fi
}

# Main function to install multi-node cluster
function installMultiNodeCluster() {
    # Initialize nodes
    initializeNodes
    
    echo "=========================================="
    echo "Kubernetes Multi-Node Cluster Installation"
    echo "=========================================="
    echo ""
    echo "Cluster configuration:"
    echo "  Master nodes: $NUM_MASTERS"
    for i in $(seq 0 $((NUM_MASTERS-1))); do
        echo "    - ${MASTER_HOSTNAMES[$i]} (${MASTER_IPS[$i]})"
    done
    echo "  Worker nodes: $NUM_WORKERS"
    for i in $(seq 0 $((NUM_WORKERS-1))); do
        echo "    - ${WORKER_HOSTNAMES[$i]} (${WORKER_IPS[$i]})"
    done
    echo ""
    
    # Check for required utilities
    if ! command -v nc &>/dev/null && ! command -v netcat &>/dev/null; then
        echo "Installing netcat..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        apt install -y netcat-openbsd &>/dev/null
    fi
    
    # Check for Ubuntu image
    if [ ! -f "/var/lib/libvirt/images/ubuntu-root.img" ]; then
        echo "Ubuntu image not found. Downloading..."
        if [ ! -f "$SCRIPT_DIR/kvm-install.sh" ]; then
            echo "Error: kvm-install.sh not found"
            exit 1
        fi
        chmod +x "$SCRIPT_DIR/kvm-install.sh"
        cd "$PROJECT_ROOT" && "$SCRIPT_DIR/kvm-install.sh" --full || {
            echo "Error: Failed to download Ubuntu image"
        exit 1
        }
    fi
    
    # Setup libvirt network for cluster
    echo ""
    echo "Setting up libvirt network for Kubernetes cluster..."
    if [ ! -f "$SCRIPT_DIR/setup-libvirt-network.sh" ]; then
        echo "Error: setup-libvirt-network.sh not found"
        exit 1
    fi
    chmod +x "$SCRIPT_DIR/setup-libvirt-network.sh"
    # Pass number of nodes to network setup script
    NUM_MASTERS="$NUM_MASTERS" NUM_WORKERS="$NUM_WORKERS" "$SCRIPT_DIR/setup-libvirt-network.sh" || {
        echo "Error: Failed to setup libvirt network"
        exit 1
    }
    
    # Check and stop existing ubuntu-noble VM (if running)
    # to avoid lock conflicts when creating new VMs
    if virsh list --name | grep -q "^ubuntu-noble$"; then
        echo ""
        echo "Warning: VM ubuntu-noble is running. Stopping it to avoid disk lock conflicts..."
        virsh shutdown ubuntu-noble 2>/dev/null || true
        sleep 5
        # Force shutdown if didn't stop
        if virsh list --name | grep -q "^ubuntu-noble$"; then
            virsh destroy ubuntu-noble 2>/dev/null || true
        fi
        echo "VM ubuntu-noble stopped"
    fi
    
    # Create all VM nodes
    echo ""
    echo "Step 1: Creating VM nodes..."
    
    # Create masters
    for i in $(seq 0 $((NUM_MASTERS-1))); do
        createVMNode "${MASTER_NAMES[$i]}" "${MASTER_IPS[$i]}" "${MASTER_HOSTNAMES[$i]}" || exit 1
    done
    
    # Create workers
    for i in $(seq 0 $((NUM_WORKERS-1))); do
        createVMNode "${WORKER_NAMES[$i]}" "${WORKER_IPS[$i]}" "${WORKER_HOSTNAMES[$i]}" || exit 1
    done
    
    # Install Kubernetes on first master
    echo ""
    echo "Step 2: Installing Kubernetes on ${MASTER_HOSTNAMES[0]} (first master)..."
    installKubernetesOnNode "${MASTER_HOSTNAMES[0]}" "${MASTER_IPS[0]}" || exit 1
    
    # Get join token
    echo ""
    echo "Step 3: Getting join token from ${MASTER_HOSTNAMES[0]}..."
    getJoinToken "${MASTER_IPS[0]}" || exit 1
    
    # Install Kubernetes on remaining masters
    if [ "$NUM_MASTERS" -gt 1 ]; then
        echo ""
        echo "Step 4: Installing Kubernetes on additional master nodes..."
        for i in $(seq 1 $((NUM_MASTERS-1))); do
            installKubernetesOnNode "${MASTER_HOSTNAMES[$i]}" "${MASTER_IPS[$i]}" || exit 1
        done
        
        # Join masters to cluster
        echo ""
        echo "Step 5: Joining master nodes to cluster..."
        for i in $(seq 1 $((NUM_MASTERS-1))); do
            joinMasterNode "${MASTER_HOSTNAMES[$i]}" "${MASTER_IPS[$i]}" || exit 1
        done
    fi
    
    # Install Kubernetes on workers
    if [ "$NUM_WORKERS" -gt 0 ]; then
        echo ""
        echo "Step 6: Installing Kubernetes on worker nodes..."
        for i in $(seq 0 $((NUM_WORKERS-1))); do
            installKubernetesOnNode "${WORKER_HOSTNAMES[$i]}" "${WORKER_IPS[$i]}" || exit 1
        done
        
        # Join workers to cluster
        echo ""
        echo "Step 7: Joining worker nodes to cluster..."
        for i in $(seq 0 $((NUM_WORKERS-1))); do
            joinWorkerNode "${WORKER_HOSTNAMES[$i]}" "${WORKER_IPS[$i]}" || exit 1
        done
    fi

    # Copy kubeconfig to host
    echo ""
    echo "Step 8: Copying kubeconfig to host..."
    copyKubeconfigToHost
    
    echo ""
    echo "=========================================="
    echo "Installation completed successfully!"
    echo "=========================================="
    echo ""
    echo "Cluster nodes:"
    echo -n "  Masters: "
    for i in $(seq 0 $((NUM_MASTERS-1))); do
        echo -n "${MASTER_HOSTNAMES[$i]}"
        if [ $i -lt $((NUM_MASTERS-1)) ]; then
            echo -n ", "
        fi
    done
    echo ""
    if [ "$NUM_WORKERS" -gt 0 ]; then
        echo -n "  Workers: "
        for i in $(seq 0 $((NUM_WORKERS-1))); do
            echo -n "${WORKER_HOSTNAMES[$i]}"
            if [ $i -lt $((NUM_WORKERS-1)) ]; then
                echo -n ", "
            fi
        done
        echo ""
    fi
    echo ""
    echo "To access the cluster:"
    echo "  export KUBECONFIG=$PROJECT_ROOT/data/kubeconfig/config"
    echo "  kubectl get nodes"
}

# Main execution
isRoot

installMultiNodeCluster
