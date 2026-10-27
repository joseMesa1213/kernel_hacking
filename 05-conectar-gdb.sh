#!/usr/bin/env bash
# Conecta gdb a KGDB (ejecutar en OTRA terminal, con la VM ya arrancada).
set -euo pipefail
cd "$(dirname "$0")/linux-7.2.7"
exec gdb -q \
  -iex "add-auto-load-safe-path $PWD" \
  -ex "set pagination off" \
  -ex "target remote 127.0.0.1:1234" \
  vmlinux
