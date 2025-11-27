#!/bin/bash

set -e

# Configuration variables
VM_NAME=ubuntu-noble
KUBE_PASSWORD="root123"
VM_IP=192.168.0.1
APT_UPDATED=0

# Network configuration for Xen VMs
XEN_NETWORK_BASE="10.44.44"
XEN_NETWORK_GATEWAY="${XEN_NETWORK_BASE}.1"
XEN_NETWORK_MASK="255.255.255.0"
XEN_BRIDGE="xenlan44"

# VM configuration
VM_MEMORY="2gb"
VM_VCPUS=2
VM_DIST="bullseye"

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "Error: You need to run this script as root"
		exit 1
	fi
}
isRoot

function getUbuntuVm() {
    if [ ! -f ./kvm-install.sh ]; then
        echo "Error: kvm-install.sh not found in current directory"
        exit 1
    fi
    
    chmod +x ./kvm-install.sh
    if ! virsh list --all --name | grep -q "^${VM_NAME}$"; then
        echo "Creating new VM: ${VM_NAME}"
        ./kvm-install.sh --full
    else
        echo "VM ${VM_NAME} already exists, showing management menu"
        ./kvm-install.sh
    fi
}

function diskConfigure() {
    if ! command -v pvcreate &>/dev/null; then
        echo "Error: LVM tools not found. Installing lvm2..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        apt install -y lvm2 &>/dev/null
    fi
    
    if [ ! -b /dev/vdb ]; then
        echo "Warning: /dev/vdb not found. Skipping disk configuration."
        return 0
    fi
    
    if ! vgs | grep -q vg0; then
        echo "Configuring LVM volume group vg0 on /dev/vdb"
        if ! pvcreate /dev/vdb; then
            echo "Error: Failed to create physical volume on /dev/vdb"
            return 1
        fi
        if ! vgcreate vg0 /dev/vdb; then
            echo "Error: Failed to create volume group vg0"
            return 1
        fi
        echo "LVM volume group vg0 created successfully"
    else
        echo "Volume group vg0 already exists"
    fi
}

# xen-tools requires the classic .list file format
function fixClassicAptList() {
    if [[ "$1" == "--undo" ]]; then
        if [ -f /etc/apt/sources.list.disabled ]; then
            mv /etc/apt/sources.list.disabled /etc/apt/sources.list
        fi
        [[ "$APT_UPDATED" != "1" ]] && apt update && APT_UPDATED=1
        if [ -f /etc/apt/sources.list.d/ubuntu.sources.disabled ]; then
            mv /etc/apt/sources.list.d/ubuntu.sources.disabled \
                /etc/apt/sources.list.d/ubuntu.sources
        fi
        echo "Classic apt sources list reverted"
        return 0
    fi
    
    if [ ! -f /etc/apt/sources.list.d/ubuntu.sources.disabled ]; then
        if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ]; then
            echo "Warning: /etc/apt/sources.list.d/ubuntu.sources not found"
            return 0
        fi
        
        echo "Converting to classic apt sources list format"
        tee /etc/apt/sources.list >/dev/null <<EOF
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
        mv /etc/apt/sources.list.d/ubuntu.sources \
            /etc/apt/sources.list.d/ubuntu.sources.disabled
        echo "Updating apt packages..."
        if ! apt update &>/dev/null; then
            echo "Error: Failed to update apt packages"
            return 1
        fi
        echo "Apt packages updated successfully"
        # To undo, run with --undo argument
    else
        echo "Classic apt sources list already configured"
    fi
}

function checkXen() {
    if ! dpkg -s "xen-tools" &>/dev/null; then
        echo "xen-tools is not installed, installing..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        if ! apt install -y xen-tools &>/dev/null; then
            echo "Error: Failed to install xen-tools"
            return 1
        fi
        echo "xen-tools installed successfully"
    else
        echo "xen-tools is already installed"
    fi
    
    if ! dpkg -s "xen-hypervisor-4.17-amd64" &>/dev/null; then
        echo "xen-hypervisor is not installed, installing..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        if ! apt install -y xen-hypervisor &>/dev/null; then
            echo "Error: Failed to install xen-hypervisor"
            return 1
        fi
        echo "xen-hypervisor installed successfully"
    else
        echo "xen-hypervisor is already installed"
    fi
}

function skelSshConfig() {
    if [ ! -f /etc/xen-tools/skel/authorized_keys ]; then
        if [ ! -f /root/.ssh/authorized_keys ]; then
            echo "Warning: /root/.ssh/authorized_keys not found. Creating directory structure only."
            mkdir -p /etc/xen-tools/skel/root/.ssh
        else
            mkdir -p /etc/xen-tools/skel/root/.ssh
            if ! cp /root/.ssh/authorized_keys /etc/xen-tools/skel/root/.ssh/; then
                echo "Error: Failed to copy authorized_keys"
                return 1
            fi
            echo "authorized_keys copied to skel directory"
        fi
    else
        echo "authorized_keys already exists in skel directory"
    fi
    
    if [ ! -f /etc/xen-tools/skel/etc/ssh/sshd_config ]; then
        if [ ! -f /etc/ssh/sshd_config ]; then
            echo "Warning: /etc/ssh/sshd_config not found"
            return 0
        fi
        mkdir -p /etc/xen-tools/skel/etc/ssh
        if ! cp /etc/ssh/sshd_config /etc/xen-tools/skel/etc/ssh/; then
            echo "sshd_config copied to skel directory"
        else
            echo "Error: Failed to copy sshd_config"
            return 1
        fi
    else
        echo "sshd_config already exists in skel directory"
    fi
}

function createImages() {
    local hostname=$1
    local ip_suffix=$2
    local ip="${XEN_NETWORK_BASE}.${ip_suffix}"
    local mac=$(printf "00:16:3e:44:44:%02x" $ip_suffix)

    if [ ! -f /etc/xen/${hostname}.pv ]; then
        echo "Creating Xen image for ${hostname} (IP: ${ip})"
        if ! xen-create-image \
            --hostname=${hostname} \
            --memory=${VM_MEMORY} \
            --vcpus=${VM_VCPUS} \
            --lvm=vg0 \
            --ip=${ip} \
            --mac=${mac} \
            --pygrub \
            --dist=${VM_DIST} \
            --noswap \
            --noaccounts \
            --noboot \
            --nocopyhosts \
            --extension=.pv \
            --fs=ext4 \
            --genpass=0 \
            --password=${KUBE_PASSWORD} \
            --nohosts \
            --bridge=${XEN_BRIDGE} \
            --gateway=${XEN_NETWORK_GATEWAY} \
            --netmask=${XEN_NETWORK_MASK}; then
            echo "Error: Failed to create image for ${hostname}"
            return 1
        fi
        echo "Image for ${hostname} created successfully"
    else
        echo "${hostname}.pv already exists, skipping"
    fi
}

function createSomeImages() {
    echo "Creating Xen images for Kubernetes cluster nodes..."
    createImages "master01" 11
    createImages "master02" 12
    createImages "master03" 13
    createImages "worker01" 14
    createImages "worker02" 15
    echo "All Xen images created"
}

function addLocaltime() {
    local hostname=$1
    local config_file="/etc/xen/${hostname}.pv"

    if [ ! -f "$config_file" ]; then
        echo "Warning: ${config_file} not found, skipping localtime configuration"
        return 0
    fi

    if ! grep -q "localtime" "$config_file"; then
        if ! echo "localtime = 1" | tee -a "$config_file" >/dev/null; then
            echo "Error: Failed to add localtime to ${config_file}"
            return 1
        fi
        echo "localtime added to ${hostname} configuration"
    else
        echo "localtime already configured for ${hostname}"
    fi
}

function addSomeLocaltime() {
    echo "Configuring localtime for all VMs..."
    addLocaltime "master01"
    addLocaltime "master02"
    addLocaltime "master03"
    addLocaltime "worker01"
    addLocaltime "worker02"
}

function createMasterVms() {
    echo "Creating master node VMs..."
    local vms=("master01" "master02" "master03")
    
    for vm in "${vms[@]}"; do
        local config_file="/etc/xen/${vm}.pv"
        if [ ! -f "$config_file" ]; then
            echo "Error: Configuration file ${config_file} not found"
            return 1
        fi
        
        if xl list | grep -q "^${vm}"; then
            echo "${vm} is already running"
        else
            echo "Starting ${vm}..."
            if ! xl create "$config_file"; then
                echo "Error: Failed to create ${vm}"
                return 1
            fi
            echo "${vm} started successfully"
        fi
    done
    echo "All master node VMs created"
}

function connectWithSSH() {
    local max_attempts=30
    local attempt=0
    
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
    while ! nc -z "$VM_IP" 22 2>/dev/null; do
        attempt=$((attempt + 1))
        if [ $attempt -ge $max_attempts ]; then
            echo "Error: VM did not become accessible after $max_attempts attempts"
            exit 1
        fi
        sleep 5
        echo "Waiting for VM to be accessible... (attempt $attempt/$max_attempts)"
    done
    echo "VM is accessible at ${VM_IP}"

    if [ ! -f ./keys/rsa.key ]; then
        echo "Error: SSH key ./keys/rsa.key not found"
        exit 1
    fi
    
    chmod 600 ./keys/rsa.key
    if [ -n "$SUDO_USER" ] && [ "${EUID}" -eq 0 ]; then
        chown "$SUDO_USER:$SUDO_USER" ./keys/rsa.key
        [ -f ./keys/rsa.key.pub ] && chown "$SUDO_USER:$SUDO_USER" ./keys/rsa.key.pub
    fi
    
    # Check if quickstart.sh exists, if not, use quickinstall.sh
    local script_to_copy="quickstart.sh"
    if [ ! -f ./quickstart.sh ]; then
        if [ -f ./quickinstall.sh ]; then
            script_to_copy="quickinstall.sh"
            echo "Warning: quickstart.sh not found, using quickinstall.sh instead"
        else
            echo "Error: Neither quickstart.sh nor quickinstall.sh found"
            exit 1
        fi
    fi
    
    echo "Copying files to VM..."
    scp -i ./keys/rsa.key \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "./${script_to_copy}" \
        "ubuntu@${VM_IP}:~/" || {
        echo "Error: Failed to copy ${script_to_copy}"
        exit 1
    }

    if [ -f ./variables.sh ]; then
        scp -i ./keys/rsa.key \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            ./variables.sh \
            "ubuntu@${VM_IP}:~/" || {
            echo "Warning: Failed to copy variables.sh"
        }
    fi

    if [ -f ./fix-boot.sh ]; then
        scp -i ./keys/rsa.key \
            -o StrictHostKeyChecking=accept-new \
            -o ConnectTimeout=10 \
            ./fix-boot.sh \
            "ubuntu@${VM_IP}:~/" || {
            echo "Warning: Failed to copy fix-boot.sh"
        }
    fi

    echo "Executing script on VM..."
    ssh -t -i ./keys/rsa.key \
        -o StrictHostKeyChecking=accept-new \
        -o ConnectTimeout=10 \
        "ubuntu@${VM_IP}" \
        "IS_VM=1 sudo -E ./${script_to_copy}" || {
        echo "Error: Failed to execute script on VM"
        exit 1
    }
}

# Main execution
if [[ "$IS_VM" == "1" ]]; then
    echo "Running in VM mode: Setting up Xen and Kubernetes cluster nodes"
    diskConfigure
    fixClassicAptList
    checkXen
    skelSshConfig
    createSomeImages
    addSomeLocaltime
    createMasterVms
else
    echo "Running in host mode: Setting up Ubuntu VM and connecting via SSH"
    getUbuntuVm
    connectWithSSH
fi