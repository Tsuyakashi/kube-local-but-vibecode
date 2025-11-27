#!/bin/bash

# Скрипт для тестирования установки Kubernetes
# Помогает диагностировать проблемы на каждом этапе

set -e

VM_NAME="ubuntu-noble"
VM_IP=""
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

function print_test() {
    echo -e "${YELLOW}[TEST]${NC} $1"
}

function print_success() {
    echo -e "${GREEN}[OK]${NC} $1"
}

function print_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

function get_vm_ip() {
    print_test "Getting VM IP address..."
    if ! virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; then
        print_error "VM ${VM_NAME} is not running or not accessible"
        return 1
    fi
    
    VM_IP=$(virsh domifaddr "$VM_NAME" 2>/dev/null | awk '/ipv4/ { split($4, a, "/"); print a[1] }')
    if [ -z "$VM_IP" ]; then
        print_error "Could not determine VM IP address"
        return 1
    fi
    print_success "VM IP: ${VM_IP}"
}

function test_ssh_connection() {
    print_test "Testing SSH connection..."
    if [ ! -f "$PROJECT_ROOT/data/keys/rsa.key" ]; then
        print_error "SSH key not found at $PROJECT_ROOT/data/keys/rsa.key"
        return 1
    fi
    
    if ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        -o BatchMode=yes \
        "ubuntu@${VM_IP}" "echo 'SSH connection OK'" &>/dev/null; then
        print_success "SSH connection works"
        return 0
    else
        print_error "SSH connection failed"
        return 1
    fi
}

function test_vm_environment() {
    print_test "Checking VM environment..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== System Info ==="
        uname -a
        echo ""
        echo "=== Disk Space ==="
        df -h /
        echo ""
        echo "=== Memory ==="
        free -h
        echo ""
        echo "=== Network ==="
        ip addr show
        echo ""
        echo "=== Package Manager ==="
        which apt && apt --version || echo "apt not found"
EOF
}

function test_containerd() {
    print_test "Checking Containerd installation..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== Containerd Binary ==="
        if [ -f /usr/local/bin/containerd ]; then
            echo "✓ containerd found: $(/usr/local/bin/containerd --version 2>&1 | head -1)"
        else
            echo "✗ containerd not found"
        fi
        
        echo ""
        echo "=== Containerd Service ==="
        systemctl status containerd --no-pager -l || echo "Service not running"
        
        echo ""
        echo "=== Runc ==="
        if [ -f /usr/local/sbin/runc ]; then
            echo "✓ runc found: $(/usr/local/sbin/runc --version 2>&1 | head -1)"
        else
            echo "✗ runc not found"
        fi
        
        echo ""
        echo "=== CNI Plugins ==="
        if [ -d /opt/cni/bin ]; then
            echo "✓ CNI plugins directory exists"
            ls -1 /opt/cni/bin | head -5
        else
            echo "✗ CNI plugins not found"
        fi
EOF
}

function test_kubernetes_repo() {
    print_test "Checking Kubernetes repository..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== Repository File ==="
        if [ -f /etc/apt/sources.list.d/kubernetes.list ]; then
            echo "✓ Repository file exists:"
            cat /etc/apt/sources.list.d/kubernetes.list
        else
            echo "✗ Repository file not found"
        fi
        
        echo ""
        echo "=== GPG Key ==="
        if [ -f /usr/share/keyrings/kubernetes-archive-keyring.gpg ]; then
            echo "✓ GPG key file exists"
        elif apt-key list 2>/dev/null | grep -q "Kubernetes"; then
            echo "✓ GPG key found in apt-key"
        else
            echo "✗ GPG key not found"
        fi
        
        echo ""
        echo "=== Testing Repository Access ==="
        apt update 2>&1 | grep -i "kubernetes\|error\|failed" | head -10 || echo "Repository update OK"
EOF
}

function test_kubernetes_packages() {
    print_test "Checking Kubernetes packages..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== Installed Packages ==="
        dpkg -l | grep -E "kubelet|kubeadm|kubectl" || echo "No Kubernetes packages installed"
        
        echo ""
        echo "=== Available Versions ==="
        apt-cache madison kubelet kubeadm kubectl 2>/dev/null | head -10 || echo "Cannot query package versions"
        
        echo ""
        echo "=== Package Status ==="
        for pkg in kubelet kubeadm kubectl; do
            if dpkg -s "$pkg" &>/dev/null; then
                echo "✓ $pkg: $(dpkg -s "$pkg" | grep Version | cut -d' ' -f2)"
            else
                echo "✗ $pkg: not installed"
            fi
        done
EOF
}

function test_installation_log() {
    print_test "Checking installation log..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        if [ -f /tmp/k8s-install.log ]; then
            echo "=== Last 50 lines of log ==="
            tail -50 /tmp/k8s-install.log
            echo ""
            echo "=== Errors in log ==="
            grep -i "error\|failed\|fatal" /tmp/k8s-install.log | tail -20 || echo "No errors found"
        else
            echo "✗ Log file not found"
        fi
EOF
}

function test_system_resources() {
    print_test "Checking system resources..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== CPU Info ==="
        nproc
        echo ""
        echo "=== Memory Usage ==="
        free -h
        echo ""
        echo "=== Disk Usage ==="
        df -h
        echo ""
        echo "=== Load Average ==="
        uptime
EOF
}

function test_network_connectivity() {
    print_test "Testing network connectivity..."
    ssh -i "$PROJECT_ROOT/data/keys/rsa.key" \
        -o StrictHostKeyChecking=accept-new \
        "ubuntu@${VM_IP}" <<'EOF'
        echo "=== Testing external connectivity ==="
        if curl -s --max-time 5 https://packages.cloud.google.com >/dev/null; then
            echo "✓ Can reach packages.cloud.google.com"
        else
            echo "✗ Cannot reach packages.cloud.google.com"
        fi
        
        if curl -s --max-time 5 https://apt.kubernetes.io >/dev/null; then
            echo "✓ Can reach apt.kubernetes.io"
        else
            echo "✗ Cannot reach apt.kubernetes.io"
        fi
        
        echo ""
        echo "=== DNS resolution ==="
        nslookup packages.cloud.google.com 2>/dev/null || echo "DNS resolution failed"
EOF
}

function run_specific_test() {
    local test_name=$1
    case "$test_name" in
        ssh)
            test_ssh_connection
            ;;
        env)
            test_vm_environment
            ;;
        containerd)
            test_containerd
            ;;
        repo)
            test_kubernetes_repo
            ;;
        packages)
            test_kubernetes_packages
            ;;
        log)
            test_installation_log
            ;;
        resources)
            test_system_resources
            ;;
        network)
            test_network_connectivity
            ;;
        *)
            echo "Unknown test: $test_name"
            return 1
            ;;
    esac
}

function run_all_tests() {
    echo "=========================================="
    echo "Kubernetes Installation Diagnostic Tests"
    echo "=========================================="
    echo ""
    
    get_vm_ip || exit 1
    echo ""
    
    test_ssh_connection || exit 1
    echo ""
    
    test_vm_environment
    echo ""
    
    test_containerd
    echo ""
    
    test_kubernetes_repo
    echo ""
    
    test_kubernetes_packages
    echo ""
    
    test_installation_log
    echo ""
    
    test_system_resources
    echo ""
    
    test_network_connectivity
    echo ""
    
    echo "=========================================="
    echo "Tests completed"
    echo "=========================================="
}

# Main
if [ $# -eq 0 ]; then
    run_all_tests
elif [ "$1" == "--help" ] || [ "$1" == "-h" ]; then
    echo "Usage: $0 [test_name]"
    echo ""
    echo "Available tests:"
    echo "  ssh        - Test SSH connection"
    echo "  env        - Check VM environment"
    echo "  containerd - Check Containerd installation"
    echo "  repo       - Check Kubernetes repository"
    echo "  packages   - Check Kubernetes packages"
    echo "  log        - Check installation log"
    echo "  resources  - Check system resources"
    echo "  network    - Test network connectivity"
    echo ""
    echo "Run without arguments to execute all tests"
else
    get_vm_ip || exit 1
    run_specific_test "$1"
fi

