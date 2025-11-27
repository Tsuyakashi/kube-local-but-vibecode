#!/bin/bash

set -e

VM_NAME=ubuntu-noble
KUBE_PASSWORD="root123"
VM_IP=192.168.0.1
APT_UPDATED=0

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}
isRoot

function getUbuntuVm(){
    if ! virsh list | grep -q "$VM_NAME"; then
        chmod +x ./kvm-install.sh
        ./kvm-install.sh --ubuntu --full
    else
        echo "VM already exists"
    fi
}

function diskConfigure() {
    if ! vgs | grep -q vg0; then
        pvcreate /dev/vdb
        vgcreate vg0 /dev/vdb
    fi
}

# xen-tools requires the classic .list file 
function fixClassicAptList() {
    if [[ "$1" == "--undo" ]]; then
        mv /etc/apt/sources.list \
        /etc/apt/sources.list.disabled
        [[ "$APT_UPDATED" != "1" ]] && apt update && APT_UPDATED=1
        mv /etc/apt/sources.list.d/ubuntu.sources.disabled \
            /etc/apt/sources.list.d/ubuntu.sources
        return 1
    fi
    if [ ! -f /etc/apt/sources.list.d/ubuntu.sources.disabled ]; then
        echo "Making classic apt sources list"
        tee /etc/apt/sources.list >/dev/null <<EOF
deb http://archive.ubuntu.com/ubuntu noble main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-updates main restricted universe multiverse
deb http://archive.ubuntu.com/ubuntu noble-backports main restricted universe multiverse
deb http://security.ubuntu.com/ubuntu noble-security main restricted universe multiverse
EOF
        mv /etc/apt/sources.list.d/ubuntu.sources \
            /etc/apt/sources.list.d/ubuntu.sources.disabled
        echo "Updating apt packages..."
        apt update &>/dev/null
        echo "Apt packages updated."
        # to Undo run with --undo
    fi
}

function checkXen () {
    if ! dpkg -s "xen-tools" &>/dev/null; then
        echo "xen-tools do not installed, so will be installed."
        echo "Installing xen-tools packages..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        apt install -y xen-tools &>/dev/null
        echo "xen-tools installed"
    fi
    if ! dpkg -s "xen-hypervisor-4.17-amd64" &>/dev/null; then
        echo "xen-hypervisor do not installed, so will be installed."
        echo "installing xen-hypervisor packages..."
        [[ "$APT_UPDATED" != "1" ]] && apt update &>/dev/null && APT_UPDATED=1
        apt install -y xen-hypervisor &>/dev/null
        echo "xen-hypervisor installed."
    fi
}

function skelSshConfig {
    if [ ! -f /etc/xen-tools/skel/authorized_keys ]; then
        mkdir -p /etc/xen-tools/skel/root/.ssh
        cp /root/.ssh/authorized_keys /etc/xen-tools/skel
    else
        echo "authorized_keys already exists"
    fi
    if [ ! -f /etc/xen-tools/skel/etc/ssh/sshd_config ]; then
        mkdir -p /etc/xen-tools/skel/etc/ssh
        cp /etc/ssh/sshd_config /etc/xen-tools/skel/etc/ssh
    else 
        echo "sshd_config already exists"
    fi
}

function createImages() {
    local hostname=$1
    local ip=10.44.44.$2
    local mac=00:16:3e:44:44:$2

    # --dir=/var/lib/xen/images
    if [ ! -f /etc/xen/$hostname.pv ]; then
        echo "Creating image for $hostname"
        xen-create-image \
        --hostname=$hostname --memory=2gb --vcpus=2 \
        --lvm=vg0 --ip=$ip --mac=$mac \
        --pygrub --dist=bullseye --noswap --noaccounts \
        --noboot --nocopyhosts --extension=.pv \
        --fs=ext4 --genpass=0 --password=$KUBE_PASSWORD --nohosts \
        --bridge=xenlan44 --gateway=10.44.44.1 --netmask=255.255.255.0
        echo "Image for $hostname created."
    else
        echo "$hostname.pv exists"
    fi
}

function createSomeImages() {
    createImages "master01" 11
    createImages "master02" 12
    createImages "master03" 13
    createImages "worker01" 14
    createImages "worker02" 15
}

function addLocaltime() {
    local hostname=$1

    if ! grep -q "localtime" /etc/xen/$hostname.pv; then
        echo "localtime = 1" | tee -a /etc/xen/$hostname.pv >/dev/null
    else
        echo "localtime for $hostname added"
    fi
}

function addSomeLocaltime() {
    addLocaltime "master01" 
    addLocaltime "master02" 
    addLocaltime "master03" 
    addLocaltime "worker01" 
    addLocaltime "worker02" 
}

function etcdCreate() {
    xl create /etc/xen/master01.pv
    xl create /etc/xen/master02.pv
    xl create /etc/xen/master03.pv
}

function connectWithSSH() {
    if ! virsh domifaddr $VM_NAME | grep -q "ipv4"; then
        echo "VM did not start"
        exit
    else
        VM_IP=$(virsh domifaddr $VM_NAME | awk '/ipv4/ { split($4, a, "/"); print a[1] }') &>/dev/null
        while ! nc -z $VM_IP 22; do
            sleep 5
            echo "VM did not accesible yet"
        done
    fi 

    
    chmod 600 ./keys/rsa.key
    if [ -n "$SUDO_USER" ] && [ "${EUID}" -eq 0 ]; then
        chown $SUDO_USER:$SUDO_USER ./keys/rsa.key
        chown $SUDO_USER:$SUDO_USER ./keys/rsa.key.pub
    fi
    scp -i ./keys/rsa.key \
        -o StrictHostKeyChecking=accept-new \
        ./quickstart.sh \
        ubuntu@$VM_IP:~/

    scp -i ./keys/rsa.key \
        -o StrictHostKeyChecking=accept-new \
        ./variables.sh \
        ubuntu@$VM_IP:~/ 

    ssh -t -i ./keys/rsa.key \
        -o StrictHostKeyChecking=accept-new \
        ubuntu@$VM_IP \
        "IS_VM=1 sudo -E ./quickstart.sh" 
    
}

if [[ "$IS_VM" == "1" ]]; then
    diskConfigure
    fixClassicAptList
    checkXen
    skelSshConfig
    createSomeImages
    addSomeLocaltime
    etcdCreate
else 
    getUbuntuVm
    connectWithSSH
fi