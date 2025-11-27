#!/bin/bash

# IP-адреса и имена хостов мастер-узлов Kubernetes. Замените на свои.
master01_IP=10.44.44.11
master02_IP=10.44.44.12
master03_IP=10.44.44.13

master01_Hostname=master01
master02_Hostname=master02
master03_Hostname=master03

# IP-адрес и имя хоста, на котором выполняется скрипт.
thisHostname=$(hostname)
thisIP=$(hostname -i)

# etcd-token. Замените на свой. Может быть любой строкой.
etcdToken=my-etcd-cluster-token

# CRI-socket.
containerdEndpoint=unix:///run/containerd/containerd.sock

# Версии пакетов. Замените на текущие актуальные.
etcdVersion=3.5.3
containerdVersion=1.6.2
runcVersion=1.1.1
cniPluginsVersion=1.1.1
kubernetesVersion=1.23.6
calicoVersion=3.22

# Пространство адресов подов. Зависит от CNI-плагина. В данном случае используется Calico.
podSubnet=192.168.0.0/16

# Пространство адресов сервисов. Замените на своё. Может быть любое, но должно быть достаточно большим.
serviceSubnet=10.46.0.0/16