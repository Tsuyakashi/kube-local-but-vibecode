#!/bin/bash

source variables.sh

etcdEnvironmentFilePath=/etc/etcd.env
serviceFilePath=/etc/systemd/system/etcd.service

function installAndConfigurePrerequisites {
  apt install curl -y
}

function downloadAndInstallEtcd {
  curl -L https://github.com/etcd-io/etcd/releases/download/v${etcdVersion}/etcd-v${etcdVersion}-linux-amd64.tar.gz --output etcd-v${etcdVersion}-linux-amd64.tar.gz
  tar -xvf etcd-v${etcdVersion}-linux-amd64.tar.gz -C /usr/local/bin/ --strip-components=1
}

function createEnvironmentFile {
cat > ${etcdEnvironmentFilePath} <<EOF
${thisHostname} > ${etcdEnvironmentFilePath}
${thisIP} >> ${etcdEnvironmentFilePath}
EOF
}

function createServiceFile {
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
}

function removeDownloads {
  rm -f etcd-v${etcdVersion}-linux-amd64.tar.gz
}

installAndConfigurePrerequisites
downloadAndInstallEtcd
createEnvironmentFile
createServiceFile
removeDownloads

systemctl enable --now etcd