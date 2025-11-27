#!/bin/bash

# IP-адреса и имена хостов мастер-узлов Kubernetes. Замените на свои.
master01_IP=10.44.44.11
master02_IP=10.44.44.12
master03_IP=10.44.44.13

master01_Hostname=master01
master02_Hostname=master02
master03_Hostname=master03

# IP-адреса и имена хостов worker-узлов Kubernetes. Замените на свои.
worker01_IP=10.44.44.21
worker02_IP=10.44.44.22

worker01_Hostname=worker01
worker02_Hostname=worker02

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
kubernetesVersion=1.28.15
calicoVersion=3.27

# Пространство адресов подов. Зависит от CNI-плагина. В данном случае используется Calico.
podSubnet=192.168.0.0/16

# Пространство адресов сервисов. Замените на своё. Может быть любое, но должно быть достаточно большим.
serviceSubnet=10.46.0.0/16

# Пароль для пользователя ubuntu в VM (по умолчанию - случайный)
# ВАЖНО: Для продакшена рекомендуется использовать более безопасный пароль или SSH ключи
# Можно переопределить через переменную окружения: export VM_PASSWORD="your-secure-password"
VM_PASSWORD="${VM_PASSWORD:-$(openssl rand -base64 32 | tr -d "=+/" | cut -c1-25)}"