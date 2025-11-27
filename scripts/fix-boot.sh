#!/bin/bash
# Скрипт для исправления проблем с загрузкой VM
# Использование: sudo ./fix-boot.sh

set -e
set -o pipefail

echo "=== Исправление проблем с загрузкой VM ==="

# Проверка прав root
if [ "${EUID}" -ne 0 ]; then
    echo "Ошибка: скрипт должен быть запущен от root"
    exit 1
fi

# 1. Обновление initramfs для всех ядер
echo "1. Обновление initramfs..."
if command -v update-initramfs &> /dev/null; then
    for kernel in /boot/vmlinuz-*; do
        if [ -f "$kernel" ]; then
            kernel_version=$(basename "$kernel" | sed 's/vmlinuz-//')
            echo "  Обновление initramfs для ядра: $kernel_version"
            update-initramfs -u -k "$kernel_version" || true
        fi
    done
else
    echo "  update-initramfs не найден, пропуск..."
fi

# 2. Проверка и исправление /etc/fstab
echo "2. Проверка /etc/fstab..."
if [ -f /etc/fstab ]; then
    # Создание резервной копии
    cp /etc/fstab /etc/fstab.backup.$(date +%Y%m%d_%H%M%S)
    
    # Получение UUID корневого раздела
    ROOT_DEVICE=$(findmnt -n -o SOURCE /)
    ROOT_UUID=$(blkid -s UUID -o value "$ROOT_DEVICE" 2>/dev/null || echo "")
    
    if [ -n "$ROOT_UUID" ]; then
        echo "  UUID корневого раздела: $ROOT_UUID"
        
        # Проверка, используется ли UUID в fstab для корневого раздела
        if ! grep -q "^UUID=$ROOT_UUID" /etc/fstab && grep -q "^[^#].*[[:space:]]/[[:space:]]" /etc/fstab; then
            echo "  Замена имени устройства на UUID в /etc/fstab..."
            # Замена устройства на UUID для корневого раздела
            sed -i "s|^\([^#][^[:space:]]*\)[[:space:]]\+/[[:space:]]|UUID=$ROOT_UUID / |" /etc/fstab
            echo "  /etc/fstab обновлен"
        else
            echo "  /etc/fstab уже использует UUID или не требует изменений"
        fi
    else
        echo "  Предупреждение: не удалось определить UUID корневого раздела"
    fi
else
    echo "  Предупреждение: /etc/fstab не найден"
fi

# 3. Обновление GRUB (если установлен)
echo "3. Обновление конфигурации GRUB..."
if command -v update-grub &> /dev/null; then
    update-grub || true
    echo "  GRUB обновлен"
elif [ -d /boot/grub ]; then
    echo "  GRUB найден, но update-grub недоступен"
else
    echo "  GRUB не установлен, пропуск..."
fi

# 4. Проверка модулей ядра для загрузки
echo "4. Проверка необходимых модулей ядра..."
REQUIRED_MODULES=("ext4" "xfs" "vfat" "dm-mod" "lvm")
for module in "${REQUIRED_MODULES[@]}"; do
    if ! grep -q "^$module" /etc/initramfs-tools/modules 2>/dev/null; then
        echo "  Добавление модуля $module в initramfs..."
        echo "$module" >> /etc/initramfs-tools/modules
    fi
done

# 5. Финальное обновление initramfs
echo "5. Финальное обновление initramfs..."
if command -v update-initramfs &> /dev/null; then
    update-initramfs -u -k all || true
fi

echo ""
echo "=== Исправление завершено ==="
echo "Рекомендуется перезагрузить VM для применения изменений:"
echo "  sudo reboot"

