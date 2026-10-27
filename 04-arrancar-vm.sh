#!/usr/bin/env bash
# Arranca la VM. ttyS0 = consola (esta terminal). ttyS1 = KGDB, en el puerto TCP 1234.
# Uso: ./04-arrancar-vm.sh          arranca normal; entra a KGDB con: echo g > /proc/sysrq-trigger
#      ./04-arrancar-vm.sh --wait   se detiene al arrancar hasta que gdb se conecte
set -euo pipefail
cd "$(dirname "$0")"
EXTRA=""
[[ "${1:-}" == "--wait" ]] && EXTRA="kgdbwait"
exec qemu-system-x86_64 \
  -enable-kvm -cpu host -smp 2 -m 1G \
  -kernel linux-7.2.7/arch/x86/boot/bzImage \
  -initrd initramfs.cpio.gz \
  -append "console=ttyS0 nokaslr kgdboc=ttyS1,115200 $EXTRA" \
  -serial mon:stdio \
  -serial tcp:127.0.0.1:1234,server=on,wait=off \
  -display none -no-reboot
