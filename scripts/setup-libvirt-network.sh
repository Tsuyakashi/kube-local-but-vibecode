#!/bin/bash

# Script to create and configure libvirt network for Kubernetes cluster

set -e
set -o pipefail

NETWORK_NAME="k8s-cluster"
NETWORK_XML="/tmp/k8s-network.xml"

# Check root privileges
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Get number of nodes from environment variables (if provided)
NUM_MASTERS="${NUM_MASTERS:-3}"
NUM_WORKERS="${NUM_WORKERS:-2}"

# Validate parameters
if ! [[ "$NUM_MASTERS" =~ ^[0-9]+$ ]] || [ "$NUM_MASTERS" -lt 1 ] || [ "$NUM_MASTERS" -gt 10 ]; then
    echo "Error: NUM_MASTERS must be between 1 and 10"
    exit 1
fi

if ! [[ "$NUM_WORKERS" =~ ^[0-9]+$ ]] || [ "$NUM_WORKERS" -lt 0 ] || [ "$NUM_WORKERS" -gt 20 ]; then
    echo "Error: NUM_WORKERS must be between 0 and 20"
    exit 1
fi

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

# Check if network exists
if virsh net-list --all --name | grep -q "^${NETWORK_NAME}$"; then
    echo "Network ${NETWORK_NAME} already exists"
    echo "Recreating network with updated DHCP reservations..."
    
    # Stop and remove existing network
    if virsh net-list --name | grep -q "^${NETWORK_NAME}$"; then
        virsh net-destroy "${NETWORK_NAME}" 2>/dev/null || true
    fi
    virsh net-undefine "${NETWORK_NAME}" 2>/dev/null || true
fi

# Create XML network configuration
cat > "$NETWORK_XML" <<EOF
<network>
  <name>${NETWORK_NAME}</name>
  <uuid>$(uuidgen)</uuid>
  <forward mode='nat'/>
  <bridge name='virbr-k8s' stp='on' delay='0'/>
  <mac address='52:54:00:44:44:00'/>
  <ip address='10.44.44.1' netmask='255.255.255.0'>
    <dhcp>
      <range start='10.44.44.100' end='10.44.44.254'/>
EOF

# Add DHCP reservations for masters
for i in $(seq 1 "$NUM_MASTERS"); do
    MAC=$(generateMAC "master" "$i")
    IP=$(generateIP "master" "$i")
    HOSTNAME=$(generateHostname "master" "$i")
    echo "      <host mac='${MAC}' name='${HOSTNAME}' ip='${IP}'/>" >> "$NETWORK_XML"
done

# Add DHCP reservations for workers
for i in $(seq 1 "$NUM_WORKERS"); do
    MAC=$(generateMAC "worker" "$i")
    IP=$(generateIP "worker" "$i")
    HOSTNAME=$(generateHostname "worker" "$i")
    echo "      <host mac='${MAC}' name='${HOSTNAME}' ip='${IP}'/>" >> "$NETWORK_XML"
done

# Close XML
cat >> "$NETWORK_XML" <<EOF
    </dhcp>
  </ip>
</network>
EOF

echo "Creating libvirt network ${NETWORK_NAME}..."
virsh net-define "$NETWORK_XML" || {
    echo "Error: Failed to define network"
    exit 1
}

echo "Starting network ${NETWORK_NAME}..."
virsh net-start "${NETWORK_NAME}" || {
    echo "Error: Failed to start network"
    exit 1
}

echo "Setting network to autostart..."
virsh net-autostart "${NETWORK_NAME}" || {
    echo "Warning: Failed to set autostart"
}

echo "Network ${NETWORK_NAME} created and started successfully"
echo "Network range: 10.44.44.0/24"
echo "Gateway: 10.44.44.1"
echo "DHCP reservations configured for all nodes"

rm -f "$NETWORK_XML"

