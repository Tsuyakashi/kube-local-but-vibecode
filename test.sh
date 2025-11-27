#!/bin/bash

set -e
set -o pipefail
# Wrapper для запуска тестов

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/scripts/test-installation.sh" "$@"

