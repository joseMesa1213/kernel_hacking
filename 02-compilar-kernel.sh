#!/usr/bin/env bash
# Compila bzImage (para arrancar), vmlinux (para gdb) y los scripts de gdb.
set -euo pipefail
cd "$(dirname "$0")/linux-7.2.7"
make -j"$(nproc)" bzImage
make scripts_gdb
ls -lh arch/x86/boot/bzImage vmlinux
