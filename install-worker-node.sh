#!/bin/bash

source variables.sh

function installAndConfigurePrerequisites {
  apt install -y apt-transport-https curl gnupg2 apparmor apparmor-utils
  curl -s https://packages.cloud.google.com/apt/doc/apt-key.gpg | apt-key add -
cat <<EOF >/etc/apt/sources.list.d/kubernetes.list
deb https://apt.kubernetes.io/ kubernetes-xenial main
EOF

  apt update
  apt install -y kubelet=$kubernetesVersion-00
  apt install -y kubeadm=$kubernetesVersion-00
  apt install -y kubectl=$kubernetesVersion-00
  apt-mark hold kubelet kubeadm kubectl
}

function joinMasterToCluster {
  read -p "Enter token: " token
  read -p "Enter SHA256 without 'sha256:' prefix: " sha
  kubeadm join 10.44.44.11:6443 --token $token --discovery-token-ca-cert-hash sha256:$sha
}

installAndConfigurePrerequisites
joinMasterToCluster