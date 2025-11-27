#!/bin/bash

source variables.sh

function installAndConfigurePrerequisites {
  apt install -y apt-transport-https curl gnupg2 apparmor apparmor-utils
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF
# Установить необходимые пакеты и зафиксировать их версию.
  apt update
  apt install -y kubelet=$kubernetesVersion-00
  apt install -y kubeadm=$kubernetesVersion-00
  apt install -y kubectl=$kubernetesVersion-00
  apt-mark hold kubelet kubeadm kubectl
}

function createKubeadmConfig {
cat > kubeadm-init.yaml <<EOF
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
  - 127.0.0.1
controlPlaneEndpoint: ${thisIP}
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
}

function initializeMasterNode {
  kubeadm init --config=kubeadm-init.yaml
}

function installCalicoCNI {
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl apply -f https://docs.projectcalico.org/v${calicoVersion}/manifests/calico.yaml
}

function archiveCertificates {
  tar -zcvf certificates.tar.gz -C /etc/kubernetes/pki .
}

function extractCertificates {
  mkdir -p /etc/kubernetes/pki
  tar -xvf certificates.tar.gz -C /etc/kubernetes/pki
}

installAndConfigurePrerequisites
createKubeadmConfig

if [[ $thisIP == $master01_IP ]]; then
  # На первом мастер-узле устанавливаем CNI-плагин и архивируем сертификаты
  # для последующего использования на других мастер-узлах.
  initializeMasterNode
  installCalicoCNI
  archiveCertificates
fi

if [[ $thisIP != $master01_IP ]]; then
  # На не первом мастер-узле используем сертификаты, полученные с первого мастер-узла.
  extractCertificates
  initializeMasterNode
fi