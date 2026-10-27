#!/usr/bin/env bash
# Arma un sistema de archivos minimo con BusyBox y los scripts de demo.
set -euo pipefail
cd "$(dirname "$0")"
rm -rf rootfs && mkdir -p rootfs/bin
cp busybox rootfs/bin/busybox
cp -r rootfs-extra/. rootfs/
(cd rootfs && find . -print0 | cpio --null -o -H newc --owner=0:0 2>/dev/null | gzip -9) > initramfs.cpio.gz
ls -lh initramfs.cpio.gz
