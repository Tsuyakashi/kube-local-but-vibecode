# kube-local-but-vibecode

Автоматическая установка Kubernetes кластера внутри VM, созданной через KVM.

## Структура проекта

```
/
├── scripts/              # Все скрипты установки
│   ├── quickinstall.sh   # Главный скрипт (создает VM и устанавливает K8s)
│   ├── kvm-install.sh    # Создание и управление KVM VM
│   ├── install-kubernetes.sh  # Установка Kubernetes внутри VM
│   └── fix-boot.sh       # Исправление проблем с загрузкой VM
├── config/               # Конфигурационные файлы
│   ├── variables.sh      # Переменные конфигурации Kubernetes
│   └── seedconfig/       # Cloud-init конфигурация для VM
├── data/                 # Данные (игнорируются git)
│   ├── images/           # Образы VM
│   └── keys/             # SSH ключи
├── install.sh            # Главный скрипт запуска (wrapper)
├── README.md
└── LICENSE
```

## Использование

### Быстрый старт

```bash
# Запуск от root
sudo ./install.sh
```

Или напрямую:

```bash
sudo ./scripts/quickinstall.sh
```

### Что делает скрипт

1. **Создает 5 VM узлов** (3 мастера + 2 воркера) с заданными IP адресами
2. **Копирует файлы** установки в каждую VM
3. **Устанавливает Kubernetes** на всех узлах последовательно:
   - Первый мастер инициализирует кластер
   - Остальные мастера присоединяются как control-plane узлы
   - Воркеры присоединяются как worker узлы
4. **Копирует kubeconfig** на хост для доступа извне

### Настройка

Отредактируйте `config/variables.sh` для настройки:
- IP-адреса master узлов (master01_IP, master02_IP, master03_IP)
- IP-адреса worker узлов (worker01_IP, worker02_IP)
- Имена хостов для всех узлов
- Версии компонентов Kubernetes
- Сетевые настройки (podSubnet, serviceSubnet)

**Важно:** Убедитесь, что сеть 10.44.44.0/24 доступна и не конфликтует с другими сетями.

## Требования

- Linux с поддержкой KVM
- Права root для создания VM
- libvirt, qemu-kvm установлены
- Достаточно места на диске для VM

## Исправление Calico CNI

Если после установки Calico не работает (несовместимость версий), используйте:

```bash
sudo ./fix-calico.sh
```

Скрипт автоматически:
- Удалит старую версию Calico 3.22
- Установит совместимую версию Calico 3.26
- Проверит статус установки

## Диагностика проблем

Если установка не удалась, используйте скрипт диагностики:

```bash
# Запустить все тесты
sudo ./test.sh

# Или конкретный тест
sudo ./test.sh ssh        # Проверка SSH соединения
sudo ./test.sh repo       # Проверка репозитория Kubernetes
sudo ./test.sh packages   # Проверка установленных пакетов
sudo ./test.sh log        # Просмотр лога установки
sudo ./test.sh network    # Проверка сетевого подключения
```

Доступные тесты:
- `ssh` - Проверка SSH соединения
- `env` - Проверка окружения VM
- `containerd` - Проверка установки Containerd
- `repo` - Проверка репозитория Kubernetes
- `packages` - Проверка пакетов Kubernetes
- `log` - Просмотр лога установки
- `resources` - Проверка ресурсов системы
- `network` - Проверка сетевого подключения

## Доступ к кластеру

### Изнутри VM
После установки kubectl уже настроен внутри VM:
```bash
ssh -i data/keys/rsa.key ubuntu@<VM_IP>
kubectl get nodes
```

### С хоста (извне)
После установки kubeconfig автоматически копируется на хост:
```bash
# Использование kubeconfig из проекта
export KUBECONFIG=$(pwd)/data/kubeconfig/config
kubectl get nodes

# Или скопировать в стандартное место
mkdir -p ~/.kube
cp data/kubeconfig/config ~/.kube/config
kubectl get nodes
```

**Важно:** Для доступа с хоста нужен установленный `kubectl`:
```bash
# Ubuntu/Debian
sudo apt-get update
sudo apt-get install -y kubectl

# Или через snap
sudo snap install kubectl --classic
```

## Примечания

- Скрипт автоматически определяет, является ли VM master или worker узлом
- Если IP VM не соответствует ни одному из настроенных master IP, создается single-node кластер
- Все установки выполняются внутри VM
- kubeconfig автоматически копируется на хост для доступа извне
- При проблемах проверьте лог на VM: `ssh -i data/keys/rsa.key ubuntu@<VM_IP> "cat /tmp/k8s-install.log"`
