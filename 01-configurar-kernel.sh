#!/usr/bin/env bash
# Configura el kernel para depurarlo con KGDB dentro de QEMU.
set -euo pipefail
cd "$(dirname "$0")/linux-7.2.7"
make defconfig
make kvm_guest.config
./scripts/config \
  -e KGDB -e KGDB_SERIAL_CONSOLE -e KGDB_KDB -e KDB_KEYBOARD \
  -e MAGIC_SYSRQ \
  -e DEBUG_INFO_DWARF5 -d DEBUG_INFO_NONE -d DEBUG_INFO_REDUCED \
  -e GDB_SCRIPTS -e FRAME_POINTER -d UNWINDER_ORC -e UNWINDER_FRAME_POINTER \
  -d RANDOMIZE_BASE \
  -e DEBUG_FS -e SCHEDSTATS
make olddefconfig
echo "Opciones de KGDB activas:"
grep -E '^CONFIG_(KGDB|KGDB_SERIAL_CONSOLE|KGDB_KDB|GDB_SCRIPTS|DEBUG_INFO_DWARF5|FRAME_POINTER)=' .config
grep -E 'CONFIG_RANDOMIZE_BASE' .config
