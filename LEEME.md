# Laboratorio: scheduler de Linux con KGDB

Kernel 7.2.7 compilado con KGDB (ya hecho). Uso:

1. Terminal 1: `./04-arrancar-vm.sh`  -> prompt `/ #` de la VM (salir: Ctrl+A, luego X)
2. En la VM:   `echo g > /proc/sysrq-trigger`  -> el kernel se congela (`kdb>`)
3. Terminal 2: `./05-conectar-gdb.sh`
4. En gdb: `break <funcion>`, `continue`, y lanzar la demo en la VM.

Demos dentro de la VM: `/demo/nice.sh`, `/demo/rt.sh`, `/demo/fork.sh`.
Usa `break` (software); `hbreak` no se dispara bajo KVM.

Si cambias algo en `rootfs-extra/`, ejecuta `./03-crear-initramfs.sh`.
La guia completa esta en el documento de estudio.
