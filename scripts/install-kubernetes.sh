#!/bin/bash

# Объединенный скрипт установки Kubernetes кластера
# Запускается внутри VM, созданной kvm-install.sh

set -e

# Проверка прав root
if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Загрузка переменных
# Скрипт запускается внутри VM, variables.sh должен быть скопирован в домашнюю директорию
if [ ! -f ./variables.sh ]; then
    echo "Error: variables.sh not found in current directory"
    echo "Make sure variables.sh is copied to VM before running this script"
    exit 1
fi
source ./variables.sh

# Определение текущего хоста и IP
thisHostname=$(hostname)
thisIP=$(hostname -I | awk '{print $1}')

echo "=========================================="
echo "Kubernetes Cluster Installation"
echo "Hostname: $thisHostname"
echo "IP: $thisIP"
echo "=========================================="

# ============================================
# 1. Настройка диска (LVM)
# ============================================
function diskConfigure() {
    echo "[1/7] Configuring disk..."
    
    if ! command -v pvcreate &>/dev/null; then
        echo "Installing lvm2..."
        apt update &>/dev/null
        apt install -y lvm2 &>/dev/null
    fi
    
    if [ ! -b /dev/vdb ]; then
        echo "Warning: /dev/vdb not found. Skipping disk configuration."
        return 0
    fi
    
    if ! vgs | grep -q vg0; then
        echo "Configuring LVM volume group vg0 on /dev/vdb"
        pvcreate /dev/vdb || return 1
        vgcreate vg0 /dev/vdb || return 1
        echo "LVM volume group vg0 created successfully"
    else
        echo "Volume group vg0 already exists"
    fi
}

# ============================================
# 2. Установка Containerd
# ============================================
function installContainerd() {
    echo "[2/7] Installing Containerd..."
    
    # Установка зависимостей
    DEBIAN_FRONTEND=noninteractive apt install -y curl
    
    # Загрузка модулей ядра
    cat <<EOF | tee /etc/modules-load.d/containerd.conf >/dev/null
overlay
br_netfilter
EOF
    
    modprobe overlay
    modprobe br_netfilter
    
    # Настройка sysctl
    cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf >/dev/null
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
    sysctl --system &>/dev/null
    
    # Загрузка и установка containerd
    if [ ! -f /usr/local/bin/containerd ]; then
        curl -L https://github.com/containerd/containerd/releases/download/v${containerdVersion}/containerd-${containerdVersion}-linux-amd64.tar.gz \
            --output /tmp/containerd-${containerdVersion}-linux-amd64.tar.gz
        tar -xvf /tmp/containerd-${containerdVersion}-linux-amd64.tar.gz -C /usr/local &>/dev/null
        rm -f /tmp/containerd-${containerdVersion}-linux-amd64.tar.gz
    fi
    
    # Создание конфигурации containerd
    mkdir -p /etc/containerd/
    if [ ! -f /etc/containerd/config.toml ]; then
        containerd config default > /etc/containerd/config.toml
        sed -i "s/SystemdCgroup = false/SystemdCgroup = true/g" /etc/containerd/config.toml
    fi
    
    # Создание сервиса containerd
    cat > /etc/systemd/system/containerd.service <<EOF
[Unit]
Description=containerd container runtime
Documentation=https://containerd.io
After=network.target local-fs.target

[Service]
ExecStartPre=-/sbin/modprobe overlay
ExecStart=/usr/local/bin/containerd

Type=notify
Delegate=yes
KillMode=process
Restart=always
RestartSec=5
LimitNPROC=infinity
LimitCORE=infinity
LimitNOFILE=infinity
TasksMax=infinity
OOMScoreAdjust=-999

[Install]
WantedBy=multi-user.target
EOF
    
    # Установка runc
    if [ ! -f /usr/local/sbin/runc ]; then
        curl -L https://github.com/opencontainers/runc/releases/download/v${runcVersion}/runc.amd64 \
            --output /tmp/runc.amd64
        install -m 755 /tmp/runc.amd64 /usr/local/sbin/runc
        rm -f /tmp/runc.amd64
    fi
    
    # Установка CNI плагинов
    if [ ! -d /opt/cni/bin ]; then
        curl -L https://github.com/containernetworking/plugins/releases/download/v${cniPluginsVersion}/cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz \
            --output /tmp/cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz
        mkdir -p /opt/cni/bin
        tar Cxzvf /opt/cni/bin /tmp/cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz &>/dev/null
        rm -f /tmp/cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz
    fi
    
    # Запуск containerd
    systemctl daemon-reload
    systemctl enable --now containerd
    systemctl restart containerd
    echo "Containerd installed successfully"
}

# ============================================
# 3. Установка etcd (только на master узлах)
# ============================================
function installEtcd() {
    echo "[3/7] Installing etcd..."
    
    # Проверка, является ли узел master
    local is_master=false
    if [[ "$thisIP" == "$master01_IP" ]] || \
       [[ "$thisIP" == "$master02_IP" ]] || \
       [[ "$thisIP" == "$master03_IP" ]]; then
        is_master=true
    fi
    
    if [ "$is_master" != true ]; then
        echo "Not a master node, skipping etcd installation"
        return 0
    fi
    
    apt install -y curl &>/dev/null
    
    # Загрузка и установка etcd
    if [ ! -f /usr/local/bin/etcd ]; then
        curl -L https://github.com/etcd-io/etcd/releases/download/v${etcdVersion}/etcd-v${etcdVersion}-linux-amd64.tar.gz \
            --output /tmp/etcd-v${etcdVersion}-linux-amd64.tar.gz
        tar -xvf /tmp/etcd-v${etcdVersion}-linux-amd64.tar.gz -C /usr/local/bin/ --strip-components=1 &>/dev/null
        rm -f /tmp/etcd-v${etcdVersion}-linux-amd64.tar.gz
    fi
    
    # Создание файла окружения
    etcdEnvironmentFilePath=/etc/etcd.env
    cat > ${etcdEnvironmentFilePath} <<EOF
ETCD_NAME=${thisHostname}
ETCD_INITIAL_CLUSTER_TOKEN=${etcdToken}
EOF
    
    # Создание сервиса etcd
    serviceFilePath=/etc/systemd/system/etcd.service
    cat > $serviceFilePath <<EOF
[Unit]
Description=etcd
Documentation=https://github.com/coreos/etcd
Conflicts=etcd.service
Conflicts=etcd2.service

[Service]
EnvironmentFile=/etc/etcd.env
Type=notify
Restart=always
RestartSec=5s
LimitNOFILE=40000
TimeoutStartSec=0

ExecStart=/usr/local/bin/etcd \\
  --name ${thisHostname} \\
  --data-dir /var/lib/etcd \\
  --listen-peer-urls http://${thisIP}:2380 \\
  --listen-client-urls http://0.0.0.0:2379 \\
  --advertise-client-urls http://${thisIP}:2379 \\
  --initial-cluster-token ${etcdToken} \\
  --initial-advertise-peer-urls http://${thisIP}:2380 \\
  --initial-cluster ${master01_Hostname}=http://${master01_IP}:2380,${master02_Hostname}=http://${master02_IP}:2380,${master03_Hostname}=http://${master03_IP}:2380 \\
  --initial-cluster-state new

[Install]
WantedBy=multi-user.target
EOF
    
    systemctl daemon-reload
    systemctl enable --now etcd
    echo "Etcd installed successfully"
}

# ============================================
# 4. Установка HAProxy (только на master узлах)
# ============================================
function installHaproxy() {
    echo "[4/7] Installing HAProxy..."
    
    # Проверка, является ли узел master
    local is_master=false
    if [[ "$thisIP" == "$master01_IP" ]] || \
       [[ "$thisIP" == "$master02_IP" ]] || \
       [[ "$thisIP" == "$master03_IP" ]]; then
        is_master=true
    fi
    
    if [ "$is_master" != true ]; then
        echo "Not a master node, skipping HAProxy installation"
        return 0
    fi
    
    # В Ubuntu 24.04 gnupg2 заменен на gnupg
    DEBIAN_FRONTEND=noninteractive apt install -y apt-transport-https curl gnupg apparmor apparmor-utils ca-certificates
    
    # Установка HAProxy из backports
    if ! dpkg -s haproxy &>/dev/null; then
        curl https://haproxy.debian.net/bernat.debian.org.gpg \
            | gpg --dearmor > /usr/share/keyrings/haproxy.debian.net.gpg
        echo deb "[signed-by=/usr/share/keyrings/haproxy.debian.net.gpg]" \
            http://haproxy.debian.net bullseye-backports-2.5 main \
            > /etc/apt/sources.list.d/haproxy.list
        
        apt update &>/dev/null
        apt install -y haproxy=2.5.* &>/dev/null
    fi
    
    # Настройка HAProxy
    cat > /etc/haproxy/haproxy.cfg <<EOF
global
	log /dev/log	local0
	log /dev/log	local1 notice
	chroot /var/lib/haproxy
	stats socket /run/haproxy/admin.sock mode 660 level admin
	stats timeout 30s
	user haproxy
	group haproxy
	daemon

	ca-base /etc/ssl/certs
	crt-base /etc/ssl/private

	ssl-default-bind-ciphers ECDH+AESGCM:DH+AESGCM:ECDH+AES256:DH+AES256:ECDH+AES128:DH+AES:RSA+AESGCM:RSA+AES:!aNULL:!MD5:!DSS
	ssl-default-bind-options no-sslv3

defaults
	log	global
	mode	http
	option	httplog
	option	dontlognull
  timeout connect 5000
  timeout client  50000
  timeout server  50000
	errorfile 400 /etc/haproxy/errors/400.http
	errorfile 403 /etc/haproxy/errors/403.http
	errorfile 408 /etc/haproxy/errors/408.http
	errorfile 500 /etc/haproxy/errors/500.http
	errorfile 502 /etc/haproxy/errors/502.http
	errorfile 503 /etc/haproxy/errors/503.http
	errorfile 504 /etc/haproxy/errors/504.http

frontend k8s-api
	bind ${thisIP}:6443
	bind 127.0.0.1:6443
	mode tcp
	option tcplog
	default_backend k8s-api

backend k8s-api
	mode tcp
	option tcplog
	option tcp-check
	balance roundrobin
	default-server port 6443 inter 10s downinter 5s rise 2 fall 2 slowstart 60s maxconn 250 maxqueue 256 weight 100
        server apiserver1 ${master01_IP}:6443 check
        server apiserver2 ${master02_IP}:6443 check
        server apiserver3 ${master03_IP}:6443 check
EOF
    
    systemctl restart haproxy
    echo "HAProxy installed and configured successfully"
}

# ============================================
# 5. Установка Kubernetes компонентов
# ============================================
function installKubernetes() {
    echo "[5/7] Installing Kubernetes components..."
    
    # Установка зависимостей с выводом прогресса
    echo "Installing prerequisites..."
    # В Ubuntu 24.04 gnupg2 заменен на gnupg
    if ! DEBIAN_FRONTEND=noninteractive apt install -y apt-transport-https curl gnupg apparmor apparmor-utils ca-certificates; then
        echo "Error: Failed to install prerequisites"
        return 1
    fi
    
    # Добавление репозитория Kubernetes
    if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
        echo "Adding Kubernetes repository..."
        mkdir -p /usr/share/keyrings
        
        # Используем новый репозиторий Kubernetes (pkgs.k8s.io)
        # Это официальный репозиторий, который заменил старый apt.kubernetes.io
        echo "Using new Kubernetes repository (pkgs.k8s.io)..."
        
        # Определяем версию Kubernetes из переменной
        K8S_MAJOR=$(echo "$kubernetesVersion" | cut -d. -f1)
        K8S_MINOR=$(echo "$kubernetesVersion" | cut -d. -f2)
        K8S_VERSION="${K8S_MAJOR}.${K8S_MINOR}"
        
        # Загружаем GPG ключ нового репозитория
        # Используем -f для автоматической перезаписи существующего файла
        if curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/Release.key" | gpg --dearmor -f -o /usr/share/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
            echo "✓ GPG key added for Kubernetes ${K8S_VERSION}"
            echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        # Fallback: используем последнюю стабильную версию
        elif curl -fsSL "https://pkgs.k8s.io/core:/stable:/v1.28/deb/Release.key" | gpg --dearmor -f -o /usr/share/keyrings/kubernetes-apt-keyring.gpg 2>/dev/null; then
            echo "✓ GPG key added for Kubernetes 1.28 (fallback)"
            echo "deb [signed-by=/usr/share/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.28/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
        # Последний fallback: старый метод (может не работать)
        elif curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -f -o /usr/share/keyrings/kubernetes-archive-keyring.gpg 2>/dev/null; then
            echo "Warning: Using legacy repository (may not work)"
            echo "deb [signed-by=/usr/share/keyrings/kubernetes-archive-keyring.gpg] https://apt.kubernetes.io/ kubernetes-xenial main" > /etc/apt/sources.list.d/kubernetes.list
        else
            echo "Error: Failed to add Kubernetes repository key"
            return 1
        fi
        
        if [ ! -f /etc/apt/sources.list.d/kubernetes.list ]; then
            echo "Error: Failed to create repository file"
            return 1
        fi
        echo "✓ Repository file created:"
        cat /etc/apt/sources.list.d/kubernetes.list
    else
        echo "Repository already configured"
    fi
    
    echo "Updating package list..."
    if ! apt update; then
        echo "Error: Failed to update package list"
        echo "Repository file content:"
        cat /etc/apt/sources.list.d/kubernetes.list || true
        return 1
    fi
    echo "✓ Package list updated"
    
    # Установка kubelet, kubeadm, kubectl
    if ! dpkg -s kubelet &>/dev/null; then
        echo "Installing kubelet, kubeadm, kubectl (version ${kubernetesVersion})..."
        
        # Проверка доступности версии
        if apt-cache madison kubelet 2>/dev/null | grep -q "${kubernetesVersion}"; then
            echo "Version ${kubernetesVersion} is available"
            if ! DEBIAN_FRONTEND=noninteractive apt install -y kubelet=${kubernetesVersion}-00 kubeadm=${kubernetesVersion}-00 kubectl=${kubernetesVersion}-00; then
                echo "Warning: Failed to install exact version ${kubernetesVersion}"
                echo "Trying latest available version..."
                DEBIAN_FRONTEND=noninteractive apt install -y kubelet kubeadm kubectl || {
                    echo "Error: Failed to install Kubernetes components"
                    return 1
                }
            fi
        else
            echo "Version ${kubernetesVersion} not available, installing latest..."
            DEBIAN_FRONTEND=noninteractive apt install -y kubelet kubeadm kubectl || {
                echo "Error: Failed to install Kubernetes components"
                return 1
            }
        fi
        
        apt-mark hold kubelet kubeadm kubectl
        
        # Определяем фактически установленную версию
        INSTALLED_K8S_VERSION=$(dpkg -s kubelet 2>/dev/null | grep Version | cut -d' ' -f2 | cut -d'-' -f1)
        if [ -n "$INSTALLED_K8S_VERSION" ]; then
            echo "Installed Kubernetes version: ${INSTALLED_K8S_VERSION}"
            # Обновляем переменную для использования в kubeadm
            kubernetesVersion="$INSTALLED_K8S_VERSION"
        fi
        
        echo "✓ Kubernetes components installed successfully"
    else
        echo "Kubernetes components already installed"
        # Определяем установленную версию
        INSTALLED_K8S_VERSION=$(dpkg -s kubelet 2>/dev/null | grep Version | cut -d' ' -f2 | cut -d'-' -f1)
        if [ -n "$INSTALLED_K8S_VERSION" ]; then
            echo "Installed Kubernetes version: ${INSTALLED_K8S_VERSION}"
            kubernetesVersion="$INSTALLED_K8S_VERSION"
        fi
    fi
}

# ============================================
# 6. Инициализация Master узлов
# ============================================
function initializeMasterNode() {
    echo "[6/7] Initializing master node..."
    
    # Определение режима работы: multi-node или single-node
    local is_master01=false
    local is_master=false
    
    if [[ "$thisIP" == "$master01_IP" ]]; then
        is_master01=true
        is_master=true
    elif [[ "$thisIP" == "$master02_IP" ]] || [[ "$thisIP" == "$master03_IP" ]]; then
        is_master=true
    fi
    
    # Создание конфигурации kubeadm
    if [ "$is_master" = true ]; then
        # Multi-node master конфигурация
        cat > /tmp/kubeadm-init.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${thisIP}"
nodeRegistration:
  criSocket: "${containerdEndpoint}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${kubernetesVersion}
apiServer:
  certSANs:
  - ${master01_IP}
  - ${master02_IP}
  - ${master03_IP}
  - ${thisIP}
  - 127.0.0.1
controlPlaneEndpoint: ${thisIP}:6443
etcd:
  external:
    endpoints:
    - http://${master01_IP}:2379
    - http://${master02_IP}:2379
    - http://${master03_IP}:2379
networking:
  podSubnet: "${podSubnet}"
  serviceSubnet: "${serviceSubnet}"
  dnsDomain: "cluster.local"
EOF
    else
        # Single-node конфигурация (если VM не соответствует ни одному из master IP)
        echo "Warning: VM IP ($thisIP) does not match any configured master IP"
        echo "Setting up as single-node cluster..."
        cat > /tmp/kubeadm-init.yaml <<EOF
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${thisIP}"
nodeRegistration:
  criSocket: "${containerdEndpoint}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${kubernetesVersion}
apiServer:
  certSANs:
  - ${thisIP}
  - 127.0.0.1
controlPlaneEndpoint: ${thisIP}:6443
networking:
  podSubnet: "${podSubnet}"
  serviceSubnet: "${serviceSubnet}"
  dnsDomain: "cluster.local"
EOF
    fi
    
    if [ "$is_master01" = true ]; then
        # Первый master узел - инициализация кластера
        echo "Initializing first master node..."
        if ! kubeadm init --config=/tmp/kubeadm-init.yaml; then
            echo "Error: kubeadm init failed"
            return 1
        fi
        
        # Проверка успешности инициализации
        if [ ! -f /etc/kubernetes/admin.conf ]; then
            echo "Error: admin.conf not found, initialization may have failed"
            return 1
        fi
        
        # Установка Calico CNI
        export KUBECONFIG=/etc/kubernetes/admin.conf
        
        # Проверка доступности кластера
        if ! kubectl cluster-info &>/dev/null; then
            echo "Warning: Cannot connect to cluster, skipping Calico installation"
        else
            # Установка Calico используя официальный манифест
            CALICO_URL="https://docs.projectcalico.org/manifests/calico.yaml"
            echo "Installing Calico CNI..."
            
            if curl -sfL "$CALICO_URL" | kubectl apply -f -; then
                echo "✓ Calico CNI installed successfully"
            else
                echo "Warning: Failed to install Calico CNI"
                echo "You can install it manually later with:"
                echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
                echo "  curl -sfL https://docs.projectcalico.org/manifests/calico.yaml | kubectl apply -f -"
            fi
        fi
        
        # Архивирование сертификатов для других master узлов
        tar -zcvf /tmp/certificates.tar.gz -C /etc/kubernetes/pki . &>/dev/null
        echo "Certificates archived to /tmp/certificates.tar.gz"
        echo "Copy this file to other master nodes before initializing them"
    elif [ "$is_master" = true ]; then
        # Другие master узлы - использование сертификатов с первого узла
        if [ ! -f /tmp/certificates.tar.gz ]; then
            echo "Error: certificates.tar.gz not found. Please copy it from master01 first."
            return 1
        fi
        
        echo "Extracting certificates from master01..."
        mkdir -p /etc/kubernetes/pki
        tar -xvf /tmp/certificates.tar.gz -C /etc/kubernetes/pki &>/dev/null
        
        echo "Initializing additional master node..."
        if ! kubeadm init --config=/tmp/kubeadm-init.yaml; then
            echo "Error: kubeadm init failed"
            return 1
        fi
    else
        # Single-node кластер
        echo "Initializing single-node cluster..."
        if ! kubeadm init --config=/tmp/kubeadm-init.yaml; then
            echo "Error: kubeadm init failed"
            return 1
        fi
        
        # Проверка успешности инициализации
        if [ ! -f /etc/kubernetes/admin.conf ]; then
            echo "Error: admin.conf not found, initialization may have failed"
            return 1
        fi
        
        # Установка Calico CNI
        export KUBECONFIG=/etc/kubernetes/admin.conf
        
        # Проверка доступности кластера
        if ! kubectl cluster-info &>/dev/null; then
            echo "Warning: Cannot connect to cluster, skipping Calico installation"
        else
            # Установка Calico используя официальный манифест
            CALICO_URL="https://docs.projectcalico.org/manifests/calico.yaml"
            echo "Installing Calico CNI..."
            
            if curl -sfL "$CALICO_URL" | kubectl apply -f -; then
                echo "✓ Calico CNI installed successfully"
            else
                echo "Warning: Failed to install Calico CNI"
                echo "You can install it manually later with:"
                echo "  export KUBECONFIG=/etc/kubernetes/admin.conf"
                echo "  curl -sfL https://docs.projectcalico.org/manifests/calico.yaml | kubectl apply -f -"
            fi
        fi
    fi
    
    # Настройка HAProxy для локального подключения
    if [ -f /etc/kubernetes/kubelet.conf ]; then
        sed -i --regexp-extended "s/(server: https:\/\/)[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}\.[[:digit:]]{1,3}/\1127.0.0.1/g" /etc/kubernetes/kubelet.conf
        systemctl restart kubelet
    fi
    
    echo "Master node initialized successfully"
}

# ============================================
# 7. Присоединение Worker узлов
# ============================================
function joinWorkerNode() {
    echo "[7/7] Joining worker node..."
    
    # Проверка, является ли узел worker
    local is_master=false
    if [[ "$thisIP" == "$master01_IP" ]] || \
       [[ "$thisIP" == "$master02_IP" ]] || \
       [[ "$thisIP" == "$master03_IP" ]]; then
        is_master=true
    fi
    
    if [ "$is_master" = true ]; then
        echo "Not a worker node, skipping worker join"
        return 0
    fi
    
    if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_CA_CERT_HASH" ]; then
        echo "Error: KUBEADM_TOKEN and KUBEADM_CA_CERT_HASH must be set"
        echo "Get these values from master01 node:"
        echo "  kubeadm token list"
        echo "  openssl x509 -pubkey -in /etc/kubernetes/pki/ca.crt | openssl rsa -pubin -outform der 2>/dev/null | openssl dgst -sha256 -hex | sed 's/^.* //'"
        return 1
    fi
    
    kubeadm join ${master01_IP}:6443 --token $KUBEADM_TOKEN --discovery-token-ca-cert-hash sha256:$KUBEADM_CA_CERT_HASH
    
    echo "Worker node joined successfully"
}

# ============================================
# Главная функция
# ============================================
function main() {
    # Создание лог-файла (с правами root)
    LOG_FILE="/tmp/k8s-install.log"
    touch "$LOG_FILE" 2>/dev/null || true
    chmod 666 "$LOG_FILE" 2>/dev/null || true
    
    echo "Installation started at $(date)"
    echo "Log file: $LOG_FILE"
    
    # Перенаправление вывода в лог (если возможно)
    if [ -w "$LOG_FILE" ]; then
        exec > >(tee -a "$LOG_FILE") 2>&1
    else
        echo "Warning: Cannot write to log file, continuing without logging"
    fi
    
    # Выполнение установки с обработкой ошибок
    if ! diskConfigure; then
        echo "Error: Disk configuration failed"
        return 1
    fi
    
    if ! installContainerd; then
        echo "Error: Containerd installation failed"
        return 1
    fi
    
    if ! installEtcd; then
        echo "Error: Etcd installation failed"
        return 1
    fi
    
    if ! installHaproxy; then
        echo "Error: HAProxy installation failed"
        return 1
    fi
    
    if ! installKubernetes; then
        echo "Error: Kubernetes components installation failed"
        return 1
    fi
    
    # Инициализация master или присоединение worker
    local is_master=false
    if [[ "$thisIP" == "$master01_IP" ]] || \
       [[ "$thisIP" == "$master02_IP" ]] || \
       [[ "$thisIP" == "$master03_IP" ]]; then
        is_master=true
    fi
    
    if [ "$is_master" = true ]; then
        if ! initializeMasterNode; then
            echo "Error: Master node initialization failed"
            return 1
        fi
    else
        # Для single-node кластера также инициализируем как master
        if [ -z "$KUBEADM_TOKEN" ] || [ -z "$KUBEADM_CA_CERT_HASH" ]; then
            echo "No join token provided, initializing as single-node cluster..."
            if ! initializeMasterNode; then
                echo "Error: Single-node cluster initialization failed"
                return 1
            fi
        else
            if ! joinWorkerNode; then
                echo "Error: Worker node join failed"
                return 1
            fi
        fi
    fi
    
    echo ""
    echo "=========================================="
    echo "Installation completed successfully!"
    echo "Installation finished at $(date)"
    echo "=========================================="
}

main

