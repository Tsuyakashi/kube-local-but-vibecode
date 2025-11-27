#!/bin/bash

set -e

VM_NAME="Amazon-Linux-2023"
VM_USER=ec2-user
VM_IMAGE=amzn2-root.qcow2
VM_IMAGE_FORMAT=qcow2
VM_IMAGE_TEMPLATE=amzn2-template.qcow2
VM_IMAGE_LINK=https://cdn.amazonlinux.com/al2023/os-images/2023.9.20251105.0/kvm/al2023-kvm-2023.9.20251105.0-kernel-6.1-x86_64.xfs.gpt.qcow2

APT_UPDATED_PACKS=0
    
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
    echo "[KVM INSTALLER]: Start $VM_NAME autoinstallaion?"
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
	echo "   2) install/check amzn image"
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
		getAmznImage
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
    echo "[KVM INSTALLER]: Installing requied packages with apt"
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
    echo "[KVM INSTALLER]: All packages are isntalled"
    echo " "
}

function checkPacks() {
    local PACKAGE_NAME="$1" 
    if ! dpkg -s "$PACKAGE_NAME" &>/dev/null; then
        if [[ APT_UPDATED_PACKS != true ]]; then
            sudo apt update &> /dev/null
            APT_UPDATED_PACKS=1
        fi
        echo "[KVM INSTALLER]: installing $PACKAGE_NAME"
        sudo apt install -y "$PACKAGE_NAME" &> /dev/null
    else
        echo "[KVM INSTALLER]: $PACKAGE_NAME is installed."
    fi
}    

function getAmznImage() {
    echo "[KVM INSTALLER]: Getting $VM_NAME image"
    if [ ! -f "./images/$VM_IMAGE_TEMPLATE" ]; then
        if [ ! -d "./images" ]; then
            mkdir images/
        fi
        wget -O ./images/$VM_IMAGE_TEMPLATE \
            $VM_IMAGE_LINK
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
    echo "[KVM INSTALLER]: Coping image"
    sudo cp \
        ./images/$VM_IMAGE_TEMPLATE \
        /var/lib/libvirt/images/$VM_IMAGE
}

function resizeImage() {
    echo "[KVM INSTALLER]: Resizing image for $IMAGE_SIZE"
    sudo qemu-img resize /var/lib/libvirt/images/$VM_IMAGE $IMAGE_SIZE &>/dev/null
}

function createDiskB() {
    echo "[KVM INSTALLER]: Creating additional disk"
    sudo qemu-img create -f qcow2 /var/lib/libvirt/images/ubuntu-noble-disk.qcow2 25G &>/dev/null
}

function keysGen() {
    if [ ! -f "./keys/rsa.key" ]; then
        echo "[KVM INSTALLER]: Generating rsa keys"
        if [ ! -d "./keys" ]; then
            mkdir keys/
        fi
        ssh-keygen -f ./keys/rsa.key -t rsa -N "" > /dev/null
        sudo chmod 644 ./keys/rsa.key
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
        tee -a seedconfig/user-data > /dev/null <<EOF
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
        tee -a seedconfig/meta-data > /dev/null <<EOF
#cloud-config
local-hostname: $VM_NAME.local
EOF
    else 
        echo "[KVM INSTALLER]: meta-data already exists"
    fi
}

function mkIso() {
    echo "[KVM INSTALLER]: Making iso"
    # I: -input-charset not specified, using utf-8 (detected in locale settings)
    sudo genisoimage \
        -output /var/lib/libvirt/images/seed.iso \
        -volid cidata \
        -joliet \
        -rock \
        ./seedconfig/user-data \
        ./seedconfig/meta-data &>/dev/null
}

function initKvm() {
    echo "[KVM INSTALLER]: Installing $VM_NAME VM"
    sudo virt-install \
        --name $VM_NAME \
        --memory $VM_MEMORY \
        --vcpus $VM_CPUS \
        --disk path=/var/lib/libvirt/images/$VM_IMAGE,format=$VM_IMAGE_FORMAT \
        --disk path=/var/lib/libvirt/images/seed.iso,device=cdrom \
        --disk path=/var/lib/libvirt/images/ubuntu-noble-disk.qcow2,format=qcow2 \
        --os-variant fedora36 \
        --virt-type kvm \
        --graphics none \
        --console pty,target_type=serial \
        --noautoconsole \
        --import &>/dev/null
}

function checkInit() {
    for i in {1..30}; do
        if virsh domifaddr $VM_NAME | grep -q "ipv4"; then
            echo "[KVM INSTALLER]: VM is running on $(virsh domifaddr $VM_NAME \
            | awk '/ipv4/ { split($4, a, "/"); print a[1] }')"
            return 0
        fi
        echo "[KVM INSTALLER]: VM is still starting"
        sleep 5
    done
    echo "VM did not become avaible in time"
    return 1
}

function fullInstall() {
    isRoot
    installRequirements
    getAmznImage
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
    virsh list | grep $VM_NAME
}

function showIP () {
    virsh domifaddr $VM_NAME
}

function shutVMDown() {
    virsh shutdown $VM_NAME
}

function destroyVM () {
    virsh destroy $VM_NAME
    virsh undefine $VM_NAME --remove-all-storage
}

FULL_FLAG=false
DEBUG_FLAG=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --ubuntu)
            VM_NAME="ubuntu-noble"
            VM_USER=ubuntu
            VM_IMAGE=ubuntu-root.img
            VM_IMAGE_FORMAT=img
            VM_IMAGE_TEMPLATE=ubuntu-template.img
            VM_IMAGE_LINK=https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
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