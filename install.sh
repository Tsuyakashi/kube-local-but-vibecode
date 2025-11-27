#!/bin/bash

set -e
set -o pipefail
# Главный скрипт установки Kubernetes кластера
# Запускает quickinstall.sh из директории scripts

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/scripts/quickinstall.sh" "$@"

