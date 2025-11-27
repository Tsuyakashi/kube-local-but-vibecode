#!/bin/bash

source variables.sh

function installAndConfigurePrerequisites {
  apt install curl -y

cat <<EOF | tee /etc/modules-load.d/containerd.conf
overlay
br_netfilter
EOF

  modprobe overlay
  modprobe br_netfilter
# Настройка обязательных параметров sysctl.
cat <<EOF | tee /etc/sysctl.d/99-kubernetes-cri.conf
net.bridge.bridge-nf-call-iptables=1
net.ipv4.ip_forward=1
net.bridge.bridge-nf-call-ip6tables=1
EOF
# Применяем изменения без перезагрузки.
  sysctl --system
}

function downloadAndInstallContainerd {
  # Загружаем релиз containerd.
  curl -L https://github.com/containerd/containerd/releases/download/v${containerdVersion}/containerd-${containerdVersion}-linux-amd64.tar.gz --output containerd-${containerdVersion}-linux-amd64.tar.gz
  tar -xvf containerd-${containerdVersion}-linux-amd64.tar.gz -C /usr/local
  # Создаём файл конфигурации containerd.
  mkdir /etc/containerd/
  containerd config default > /etc/containerd/config.toml
  # Разрешаем использование systemd cgroup.
  sed -i "s/SystemdCgroup = false/SystemdCgroup = true/g" /etc/containerd/config.toml
# Создаём файл сервиса containerd.
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
  # Разрешаем и запускаем сервис containerd.
  systemctl daemon-reload
  systemctl enable --now containerd
}

function downloadAndInstallRunc {
  # Загружаем и устанавливаем низкоуровневую службу запуска контейнеров.
  curl -L https://github.com/opencontainers/runc/releases/download/v${runcVersion}/runc.amd64 --output runc.amd64
  install -m 755 runc.amd64 /usr/local/sbin/runc
}

function downloadAndInstallCniPlugins {
  curl -L https://github.com/containernetworking/plugins/releases/download/v${cniPluginsVersion}/cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz --output cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz
  mkdir -p /opt/cni/bin
  tar Cxzvf /opt/cni/bin cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz
}

function removeDownloads {
  rm -f containerd-${containerdVersion}-linux-amd64.tar.gz
  rm -f runc.amd64
  rm -f cni-plugins-linux-amd64-v${cniPluginsVersion}.tgz
}

installAndConfigurePrerequisites
downloadAndInstallContainerd
downloadAndInstallRunc
downloadAndInstallCniPlugins
removeDownloads

systemctl restart containerd