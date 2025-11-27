#!/bin/bash

# Скрипт для исправления Calico CNI на уже установленном кластере
# Запускается внутри VM

set -e

if [ "${EUID}" -ne 0 ]; then
    echo "Error: You need to run this script as root"
    exit 1
fi

# Загрузка переменных
if [ -f ./variables.sh ]; then
    source ./variables.sh
elif [ -f /home/ubuntu/variables.sh ]; then
    source /home/ubuntu/variables.sh
else
    echo "Warning: variables.sh not found, using default calicoVersion=3.27"
    calicoVersion=3.27
fi

echo "=========================================="
echo "Fixing Calico CNI Installation"
echo "=========================================="

# Настройка KUBECONFIG
export KUBECONFIG=/etc/kubernetes/admin.conf

# Проверка доступности кластера
if ! kubectl cluster-info &>/dev/null; then
    echo "Error: Cannot connect to Kubernetes cluster"
    exit 1
fi

echo "✓ Cluster is accessible"

# Удаление старой версии Calico (если установлена)
echo "Removing old Calico installation (if exists)..."
# Удаляем все ресурсы Calico по меткам
kubectl delete daemonset calico-node -n kube-system 2>/dev/null || true
kubectl delete deployment calico-kube-controllers -n kube-system 2>/dev/null || true
kubectl delete -f https://docs.projectcalico.org/v3.22/manifests/calico.yaml 2>/dev/null || true
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.26/manifests/calico.yaml 2>/dev/null || true
kubectl delete -f https://raw.githubusercontent.com/projectcalico/calico/v3.27/manifests/calico.yaml 2>/dev/null || true

# Ожидание удаления ресурсов
sleep 5

# Установка новой версии Calico
echo "Installing Calico ${calicoVersion}..."

# Используем официальный манифест Calico (latest, совместимый с Kubernetes 1.28+)
CALICO_URL="https://docs.projectcalico.org/manifests/calico.yaml"

echo "Downloading Calico manifest from ${CALICO_URL}..."
if curl -sfL "$CALICO_URL" > /tmp/calico.yaml 2>&1; then
    echo "✓ Manifest downloaded"
    
    # Применяем манифест
    if kubectl apply -f /tmp/calico.yaml; then
        echo "✓ Calico installed successfully"
        rm -f /tmp/calico.yaml
    else
        echo "Error: Failed to apply Calico manifest"
        echo "Manifest saved to /tmp/calico.yaml for manual inspection"
        exit 1
    fi
else
    echo "Error: Failed to download Calico manifest"
    echo "HTTP Status: $(curl -sfL "$CALICO_URL" -o /dev/null -w "%{http_code}" 2>&1)"
    echo ""
    echo "Trying alternative URL..."
    
    # Альтернативный URL через curl pipe
    if curl -sfL "https://docs.projectcalico.org/manifests/calico.yaml" | kubectl apply -f -; then
        echo "✓ Calico installed successfully (alternative method)"
    else
        echo "Error: All installation methods failed"
        echo ""
        echo "Manual installation:"
        echo "  curl -sfL https://docs.projectcalico.org/manifests/calico.yaml | kubectl apply -f -"
        exit 1
    fi
fi

# Ожидание запуска подов Calico
echo "Waiting for Calico pods to be ready..."
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=120s || true

# Проверка статуса
echo ""
echo "=========================================="
echo "Calico Installation Status"
echo "=========================================="
kubectl get pods -n kube-system | grep calico || echo "Calico pods not found yet"

echo ""
echo "=========================================="
echo "Cluster Status"
echo "=========================================="
kubectl get nodes
kubectl get pods --all-namespaces

echo ""
echo "=========================================="
echo "Calico fix completed!"
echo "=========================================="

