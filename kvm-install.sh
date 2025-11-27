#!/bin/bash

set -e

VM_NAME="ubuntu-noble"
VM_USER=ubuntu
VM_IMAGE=ubuntu-root.img
VM_IMAGE_FORMAT=img
VM_IMAGE_TEMPLATE=ubuntu-template.img
VM_IMAGE_LINK=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img

APT_UPDATED=false
    
IMAGE_SIZE=20g
VM_MEMORY=2048
VM_CPUS=2

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "[KVM INSTALLER]: You need to run this script as root"
		exit 1
	fi
}

function init() {
    isRoot
    
	echo "Welcome to kvm-on-machine installer!"
	echo "The git repository is available at: https://github.com/Tsuyakashi/kvm-on-machine"
	echo ""
    echo "[KVM INSTALLER]: Start $VM_NAME autoinstallation?"
	read -n1 -r -p "Press any key to continue..."

    fullInstall
}

function manageMenu() {
	echo "Welcome to kvm-on-machine installer!"
	echo "The git repository is available at: https://github.com/Tsuyakashi/kvm-on-machine"
	echo ""
	echo "It looks like kvm-on-machine is already running/installed."
	echo ""
	echo "What do you want to do?"
	echo "   1) Show VM"
	echo "   2) Check VM ip"
	echo "   3) Shutdown VM"
	echo "   4) Destroy VM"
	echo "   5) Exit"
    until [[ ${MENU_OPTION} =~ ^[1-5]$ ]]; do
		read -rp "Select an option [1-5]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		listVM
		;;
	2)
        showIP
        ;;
    3)
		shutVMDown
		;;
	4)
		destroyVM
		;;
	5)
		exit 0
		;;
	esac
}

function debugMenu () {
    echo "Welcome to kvm-on-machine debug menu!"
	echo ""
	echo ""
	echo "What do you want to do?"
	echo "   1) install/check req"
	echo "   2) install/check VM image"
	echo "   3) check/make libvirt/images"
	echo "   4) copy template image in /var/lib/libvirt/images"
    echo "   5) generate/check keys"
    echo "   6) create/check seedconfig"
    echo "   7) create seedinfo.iso"
    echo "   8) create and run kvm"
    echo "   9) exit"

    until [[ ${MENU_OPTION} =~ ^[1-9]$ ]]; do
		read -rp "Select an option [1-9]: " MENU_OPTION
	done
	case "${MENU_OPTION}" in
	1)
		installRequirements
		;;
	2)
		getVMImage
		;;
	3)
		mkLibvirtDir
		;;
	4)
		cpImage
		;;
    5)
		keysGen
		;;
    6)
		seedConfigGen
		;;
    7)
		mkIso
		;;
    8)
		initKvm
		;;
    9)
		exit 0
		;;
    
	esac
}

function installRequirements() {
    # add installation check
    echo " "
    echo "[KVM INSTALLER]: Installing required packages with apt"
    echo " "
    
    checkPacks "bridge-utils" 
    checkPacks "cpu-checker" 
    checkPacks "libvirt-clients" 
    checkPacks "libvirt-daemon" 
    checkPacks "libvirt-daemon-system" 
    checkPacks "qemu-system-x86" 
    checkPacks "virtinst" 
    checkPacks "virt-manager" 
    checkPacks "genisoimage"

    echo " "
    echo "[KVM INSTALLER]: All packages are installed"
    echo " "
}

function checkPacks() {
    local PACKAGE_NAME="$1" 
    if ! dpkg -s "$PACKAGE_NAME" &>/dev/null; then
        if [[ "$APT_UPDATED" != true ]]; then
            sudo apt update &> /dev/null
            APT_UPDATED=true
        fi
        echo "[KVM INSTALLER]: installing $PACKAGE_NAME"
        sudo apt install -y "$PACKAGE_NAME" &> /dev/null
    else
        echo "[KVM INSTALLER]: $PACKAGE_NAME is installed."
    fi
}    

function getVMImage() {
    echo "[KVM INSTALLER]: Getting $VM_NAME image"
    if [ ! -f "./images/$VM_IMAGE_TEMPLATE" ]; then
            mkdir -p images/
        if ! wget -O "./images/$VM_IMAGE_TEMPLATE" "$VM_IMAGE_LINK"; then
            echo "[KVM INSTALLER]: Failed to download image"
            return 1
        fi
    else 
        echo "[KVM INSTALLER]: Already downloaded"
    fi
} 

function mkLibvirtDir() {
    #add cheking if allready exists
    sudo mkdir -p /var/lib/libvirt/images/
}

function cpImage() {
    #add reinstalling
    echo "[KVM INSTALLER]: Copying image"
    if [ ! -f "/var/lib/libvirt/images/$VM_IMAGE" ]; then
        sudo cp \
            "./images/$VM_IMAGE_TEMPLATE" \
            "/var/lib/libvirt/images/$VM_IMAGE"
    else
        echo "[KVM INSTALLER]: Image already exists at /var/lib/libvirt/images/$VM_IMAGE"
    fi
}

function resizeImage() {
    echo "[KVM INSTALLER]: Resizing image for $IMAGE_SIZE"
    if ! sudo qemu-img resize "/var/lib/libvirt/images/$VM_IMAGE" "$IMAGE_SIZE" &>/dev/null; then
        echo "[KVM INSTALLER]: Failed to resize image"
        return 1
    fi
}

function createDiskB() {
    local DISK_NAME="${VM_NAME}-disk.qcow2"
    echo "[KVM INSTALLER]: Creating additional disk"
    if [ ! -f "/var/lib/libvirt/images/$DISK_NAME" ]; then
        sudo qemu-img create -f qcow2 "/var/lib/libvirt/images/$DISK_NAME" 25G &>/dev/null
    else
        echo "[KVM INSTALLER]: Additional disk already exists"
    fi
}

function keysGen() {
    if [ ! -f "./keys/rsa.key" ]; then
        echo "[KVM INSTALLER]: Generating rsa keys"
        if [ ! -d "./keys" ]; then
            mkdir keys/
        fi
        ssh-keygen -f ./keys/rsa.key -t rsa -N "" > /dev/null
        chmod 600 ./keys/rsa.key
        chmod 644 ./keys/rsa.key.pub
    else
        echo "[KVM INSTALLER]: Keys already exist"
    fi
    
}

function seedConfigGen() {
    echo "[KVM INSTALLER]: Creating seed config"
    if [ ! -d "./seedconfig" ]; then
        mkdir seedconfig/
    fi
    if [ ! -f "./seedconfig/user-data" ]; then
        tee seedconfig/user-data > /dev/null <<EOF
#cloud-config
#vim:syntax=yaml
users:
  - name: $VM_USER
    gecos: some text can be here
    sudo: ALL=(ALL) NOPASSWD:ALL
    plain_text_passwd: somepassword # it will be better to edit and even to encrypt
    groups: sudo, admin
    shell: /bin/bash
    ssh_authorized_keys:
      - $(cat ./keys/rsa.key.pub)
EOF
    else 
        echo "[KVM INSTALLER]: user-data already exists"
    fi
    
    if [ ! -f "./seedconfig/meta-data" ]; then
        tee seedconfig/meta-data > /dev/null <<EOF
#cloud-config
local-hostname: $VM_NAME.local
EOF
    else 
        echo "[KVM INSTALLER]: meta-data already exists"
    fi
}

function mkIso() {
    echo "[KVM INSTALLER]: Making iso"
    if [ ! -f "./seedconfig/user-data" ] || [ ! -f "./seedconfig/meta-data" ]; then
        echo "[KVM INSTALLER]: seedconfig files not found. Run seedConfigGen first."
        return 1
    fi
    # I: -input-charset not specified, using utf-8 (detected in locale settings)
    if ! sudo genisoimage \
        -output /var/lib/libvirt/images/seed.iso \
        -volid cidata \
        -joliet \
        -rock \
        ./seedconfig/user-data \
        ./seedconfig/meta-data &>/dev/null; then
        echo "[KVM INSTALLER]: Failed to create ISO"
        return 1
    fi
}

function initKvm() {
    if virsh list --all --name | grep -q "^${VM_NAME}$"; then
        echo "[KVM INSTALLER]: VM $VM_NAME already exists. Use --debug menu to manage it."
        return 1
    fi
    
    local DISK_NAME="${VM_NAME}-disk.qcow2"
    local OS_VARIANT="generic"
    
    # Set appropriate OS variant based on VM type
    if [[ "$VM_NAME" == *"Amazon-Linux"* ]] || [[ "$VM_NAME" == *"amzn"* ]]; then
        OS_VARIANT="al2023"
    elif [[ "$VM_NAME" == *"ubuntu"* ]]; then
        OS_VARIANT="ubuntu22.04"
    fi
    
    echo "[KVM INSTALLER]: Installing $VM_NAME VM"
    sudo virt-install \
        --name "$VM_NAME" \
        --memory "$VM_MEMORY" \
        --vcpus "$VM_CPUS" \
        --disk "path=/var/lib/libvirt/images/$VM_IMAGE,format=$VM_IMAGE_FORMAT" \
        --disk "path=/var/lib/libvirt/images/seed.iso,device=cdrom" \
        --disk "path=/var/lib/libvirt/images/$DISK_NAME,format=qcow2" \
        --os-variant "$OS_VARIANT" \
        --virt-type kvm \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --import &>/dev/null
}

function checkInit() {
    for i in {1..30}; do
        if virsh domifaddr "$VM_NAME" 2>/dev/null | grep -q "ipv4"; then
            echo "[KVM INSTALLER]: VM is running on $(virsh domifaddr "$VM_NAME" \
            | awk '/ipv4/ { split($4, a, "/"); print a[1] }')"
            return 0
        fi
        echo "[KVM INSTALLER]: VM is still starting"
        sleep 5
    done
    echo "[KVM INSTALLER]: VM did not become available in time"
    return 1
}

function fullInstall() {
    isRoot
    installRequirements
    getVMImage
    mkLibvirtDir
    cpImage
    resizeImage
    createDiskB
    keysGen
    seedConfigGen
    mkIso
    initKvm
    checkInit
}

function listVM () {
    virsh list | grep "$VM_NAME"
}

function showIP () {
    virsh domifaddr "$VM_NAME"
}

function shutVMDown() {
    virsh shutdown "$VM_NAME"
}

function destroyVM () {
    virsh destroy "$VM_NAME" 2>/dev/null || true
    virsh undefine "$VM_NAME" --remove-all-storage
}

FULL_FLAG=false
DEBUG_FLAG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --amazon)
            VM_NAME="Amazon-Linux-2023"
            VM_USER=ec2-user
            VM_IMAGE=amzn2-root.qcow2
            VM_IMAGE_FORMAT=qcow2
            VM_IMAGE_TEMPLATE=amzn2-template.qcow2
            VM_IMAGE_LINK=https://cdn.amazonlinux.com/al2023/os-images/2023.9.20251105.0/kvm/al2023-kvm-2023.9.20251105.0-kernel-6.1-x86_64.xfs.gpt.qcow2
            shift
            ;;  
        --full)
            FULL_FLAG=true
            shift
            ;;
        --debug)
            DEBUG_FLAG=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            exit 1
            ;;
    esac
done

if [[ "$FULL_FLAG" == true ]];then
    isRoot
    fullInstall
    exit
fi
if [[ "$DEBUG_FLAG" == true ]]; then
    debugMenu
    exit
fi

if virsh list --all --name | grep -q "$VM_NAME"; then
    manageMenu
    exit
fi

init