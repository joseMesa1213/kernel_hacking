# Laboratorio: el scheduler de Linux visto con KGDB

Laboratorio práctico para una exposición de Sistemas Operativos sobre **cómo planifica procesos el kernel de Linux** (CFS/EEVDF, clases de planificación, `nice`, tiempo real) y cómo **observarlo en vivo con KGDB**.

Se compila un kernel Linux **7.2.7** con soporte de depuración, se arranca en una máquina virtual QEMU con un sistema mínimo (BusyBox) y desde el equipo anfitrión se conecta `gdb` al kernel para poner breakpoints en funciones del scheduler y leer sus estructuras (`task_struct`, `sched_entity`, etc.).

---

## Índice

1. [Qué se demuestra](#qué-se-demuestra)
2. [Conceptos clave](#conceptos-clave)
3. [Estructura del repositorio](#estructura-del-repositorio)
4. [Requisitos](#requisitos)
5. [Preparación (una sola vez)](#preparación-una-sola-vez)
6. [Los scripts, uno por uno](#los-scripts-uno-por-uno)
7. [Guion de la demo](#guion-de-la-demo)
8. [Resultados obtenidos](#resultados-obtenidos)
9. [Problemas conocidos y soluciones](#problemas-conocidos-y-soluciones)
10. [Referencia rápida de comandos](#referencia-rápida-de-comandos)

---

## Qué se demuestra

| Experimento | Script | Qué se ve | Usa gdb |
| --- | --- | --- | --- |
| 1. Reparto de CPU según `nice` | `/demo/nice.sh` | Dos procesos en la misma CPU con nice 0 y nice 5 reciben ~75 % / ~25 % de CPU, pero su `vruntime` queda casi igual | No |
| 2. Cambio a tiempo real | `/demo/rt.sh` | Un proceso pasa de `SCHED_NORMAL` (clase *fair*) a `SCHED_FIFO` prioridad 50 (clase *rt*) | Sí, breakpoint en `__sched_setscheduler` |
| 3. Nace un proceso | `/demo/fork.sh` | Un proceso recién creado recibe `vruntime`, `deadline` y `slice` al entrar a la runqueue | Sí, breakpoint en `wake_up_new_task` |

---

## Conceptos clave

**Procesos en Linux**
- `struct task_struct` es el PCB de Linux. Campos relevantes: `pid`, `comm`, `__state`, `prio`, `static_prio`, `policy`, `sched_class`, `se`.
- Procesos e hilos son *tasks*. `fork()` → `clone()` → `copy_process()`; la task nueva entra a la runqueue con `wake_up_new_task()`.

**Clases de planificación** (de mayor a menor prioridad: `stop` → `deadline` → `rt` → `fair` → `idle`)
- **fair** (`fair_sched_class`): `SCHED_NORMAL` / `SCHED_BATCH`. Procesos normales. Usa **EEVDF**.
- **rt** (`rt_sched_class`): `SCHED_FIFO` / `SCHED_RR`. Prioridad fija 1–99; siempre le gana a cualquier task fair. FIFO corre hasta bloquearse o ceder; RR rota entre iguales con un quantum.

**nice y peso**
- `nice` va de −20 (más CPU) a +19 (menos CPU). Se convierte en un **peso** (`se.load.weight`) con la tabla `sched_prio_to_weight`: nice 0 = 1024, nice 5 = 335, nice −5 = 3121.
- Cada punto de nice ≈ 10 % de CPU frente a un proceso con nice 0. Solo importa cuando hay competencia.
- nice 0 vs nice 5 → 1024 / (1024 + 335) ≈ **75 %** y 335 / 1359 ≈ **25 %**.

**EEVDF** (*Earliest Eligible Virtual Deadline First*, scheduler de la clase fair desde Linux 6.6)
- **`vruntime`**: tiempo de CPU "con descuento" según el peso. Por cada 1 ms real sube `1 ms × 1024 / peso` (nice 0 sube 1 ms; nice 5 sube ~3 ms). Por eso dos tasks con distinto nice terminan con `vruntime` casi igual aunque una haya corrido 3 veces más.
- **lag**: `V − vruntime`, donde `V` es el promedio ponderado de la runqueue. Lag ≥ 0 → la task es **elegible** (se le debe CPU).
- **deadline virtual**: `vruntime + slice / peso`. Entre las elegibles corre la de **deadline más cercana**.
- **slice**: `0,7 ms × (1 + log₂(CPUs))` (cuenta como máximo 8 CPUs). En la VM de 2 CPUs: **1,4 ms** (`1400000` ns). El slice es igual para todas; nice 0 no tiene turnos más largos, sino que es **elegida más veces seguidas**.

**KGDB**
- `gdb` es el depurador de GNU. KGDB es el "stub" dentro del kernel que habla el protocolo remoto de gdb: el kernel depurado se congela y otro equipo (aquí, el anfitrión) lo controla por un puerto serie.
- Se necesitan dos kernels "vistas": `bzImage` (el que arranca) y `vmlinux` (con símbolos DWARF, el que lee gdb).
- Un breakpoint es una trampa (`int3`) en una función: el kernel se congela solo cuando alguien pasa por ella.

---

## Estructura del repositorio

```
lab/
├── 01-configurar-kernel.sh   # configura el kernel con KGDB y símbolos de depuración
├── 02-compilar-kernel.sh     # compila bzImage, vmlinux y los scripts de gdb
├── 03-crear-initramfs.sh     # arma el sistema de archivos mínimo (BusyBox + demos)
├── 04-arrancar-vm.sh         # arranca la VM en QEMU con KGDB en el puerto 1234
├── 05-conectar-gdb.sh        # conecta gdb al kernel de la VM
├── rootfs-extra/             # se copia tal cual dentro del initramfs
│   ├── init                  # primer proceso de la VM (PID 1)
│   └── demo/
│       ├── nice.sh
│       ├── rt.sh
│       └── fork.sh
├── LEEME.md                  # resumen corto de uso
└── README.md
```

Archivos que **no se suben** al repositorio (se descargan o se generan, ver `.gitignore`):

| Archivo | Origen |
| --- | --- |
| `linux-7.2.7/` | Código fuente del kernel, descargado (~1,5 GB tras compilar) |
| `busybox` | Binario estático descargado |
| `rootfs/`, `initramfs.cpio.gz` | Generados por `03-crear-initramfs.sh` |
| `build.log` | Log de compilación |

---

## Requisitos

Probado en **Fedora** (x86_64) con KVM disponible.

```bash
sudo dnf install gcc make flex bison bc elfutils-libelf-devel openssl-devel \
                 perl cpio gzip xz qemu-system-x86 gdb
```

- La CPU debe tener virtualización activada (`/dev/kvm` debe existir), porque la VM usa `-enable-kvm -cpu host`.
- Unos 3 GB libres en disco y unos minutos de compilación.

---

## Preparación (una sola vez)

```bash
cd lab

# 1. Descargar el kernel y BusyBox
curl -LO https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.2.7.tar.xz
tar xf linux-7.2.7.tar.xz
curl -Lo busybox https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox
chmod +x busybox

# 2. Configurar, compilar y crear el initramfs
./01-configurar-kernel.sh
./02-compilar-kernel.sh
./03-crear-initramfs.sh
```

Cuándo volver a ejecutar cada uno:
- `01` y `02`: solo si cambias la configuración del kernel.
- `03`: cada vez que edites algo en `rootfs-extra/` (por ejemplo, una demo).

---

## Los scripts, uno por uno

Los scripts `01`–`05` se ejecutan en el **anfitrión** (Bash). Todos empiezan con:

```bash
#!/usr/bin/env bash
set -euo pipefail          # detenerse ante el primer error, variable no definida o fallo en un pipe
cd "$(dirname "$0")/..."   # trabajar siempre relativo a la carpeta del script
```

`init` y las demos se ejecutan **dentro de la VM** con el `sh` de BusyBox.

### `01-configurar-kernel.sh`
Parte de la configuración por defecto de x86_64 y activa lo necesario para depurar con KGDB dentro de QEMU.

| Línea | Para qué |
| --- | --- |
| `make defconfig` | Configuración base para x86_64 |
| `make kvm_guest.config` | Drivers para correr como invitado de KVM/QEMU (virtio, consola serie) |
| `-e KGDB -e KGDB_SERIAL_CONSOLE` | El stub de KGDB y su transporte por puerto serie (`kgdboc`) |
| `-e KGDB_KDB -e KDB_KEYBOARD` | El monitor `kdb>` que aparece al congelar el kernel |
| `-e MAGIC_SYSRQ` | Permite `echo g > /proc/sysrq-trigger` para entrar a KGDB a mano |
| `-e DEBUG_INFO_DWARF5 -d DEBUG_INFO_NONE -d DEBUG_INFO_REDUCED` | Símbolos completos para que gdb entienda tipos y variables |
| `-e GDB_SCRIPTS` | Comandos `lx-*` de gdb (`lx-ps`, `lx-dmesg`…) |
| `-e FRAME_POINTER -d UNWINDER_ORC -e UNWINDER_FRAME_POINTER` | Backtraces (`bt`) fiables |
| `-d RANDOMIZE_BASE` | Sin KASLR: las direcciones reales coinciden con las de `vmlinux` |
| `-e DEBUG_FS -e SCHEDSTATS` | Estadísticas del scheduler en `/proc/<pid>/sched` |
| `make olddefconfig` | Resuelve dependencias de las opciones cambiadas |
| `grep ... .config` | Muestra que las opciones quedaron activas |

### `02-compilar-kernel.sh`
Compila el kernel.

| Línea | Para qué |
| --- | --- |
| `make -j"$(nproc)" bzImage` | Compila con todos los núcleos. Genera `arch/x86/boot/bzImage` (comprimido, el que arranca QEMU) y `vmlinux` (sin comprimir, con símbolos, el que lee gdb) |
| `make scripts_gdb` | Genera `vmlinux-gdb.py`, que carga los comandos `lx-*` |
| `ls -lh ...` | Comprueba que existen los dos archivos |

### `03-crear-initramfs.sh`
Arma el sistema de archivos que el kernel carga en RAM al arrancar.

| Línea | Para qué |
| --- | --- |
| `rm -rf rootfs && mkdir -p rootfs/bin` | Empieza de cero cada vez |
| `cp busybox rootfs/bin/busybox` | Un solo binario que hace de `sh`, `ls`, `top`, `chrt`, `taskset`… |
| `cp -r rootfs-extra/. rootfs/` | Copia `init` y la carpeta `demo/` |
| `find . -print0 \| cpio --null -o -H newc --owner=0:0 \| gzip -9` | Empaqueta en formato `newc` (el que entiende el kernel), con dueño root, y comprime |

### `rootfs-extra/init`
Primer proceso de la VM (PID 1).

| Línea | Para qué |
| --- | --- |
| `#!/bin/busybox sh` | Al arrancar aún no existe `/bin/sh`; se usa BusyBox directamente |
| `/bin/busybox --install -s /bin` | Crea los enlaces `sh`, `ls`, `top`… |
| `mount -t proc / sysfs / devtmpfs / debugfs / tmpfs` | Monta los sistemas de archivos virtuales; `/proc` es imprescindible para `/proc/<pid>/sched` y `sysrq-trigger` |
| `echo ...` | Muestra el menú de demos |
| `exec setsid cttyhack sh` | Abre un shell con terminal de control (para que funcione `Ctrl+C`) |

### `04-arrancar-vm.sh`
Arranca la VM. Uso: `./04-arrancar-vm.sh` o `./04-arrancar-vm.sh --wait` (el kernel espera a gdb desde el arranque).

| Línea | Para qué |
| --- | --- |
| `[[ "${1:-}" == "--wait" ]] && EXTRA="kgdbwait"` | Opción para detenerse al arrancar |
| `-enable-kvm -cpu host -smp 2 -m 1G` | Virtualización por hardware, 2 CPUs, 1 GB de RAM |
| `-kernel ...bzImage -initrd initramfs.cpio.gz` | Arranca directo el kernel compilado con nuestro initramfs |
| `console=ttyS0` | Los mensajes y el shell van al primer puerto serie (esta terminal) |
| `nokaslr` | Refuerza que no haya direcciones aleatorias |
| `kgdboc=ttyS1,115200` | KGDB usa el segundo puerto serie |
| `-serial mon:stdio` | ttyS0 ↔ terminal; `Ctrl+A X` cierra QEMU |
| `-serial tcp:127.0.0.1:1234,server=on,wait=off` | ttyS1 ↔ puerto TCP 1234, donde se conecta gdb |
| `-display none -no-reboot` | Sin ventana gráfica; si el kernel se reinicia, QEMU termina |

### `05-conectar-gdb.sh`
Conecta gdb al kernel congelado (en otra terminal).

| Línea | Para qué |
| --- | --- |
| `-iex "add-auto-load-safe-path $PWD"` | Permite cargar `vmlinux-gdb.py` (comandos `lx-*`) |
| `-ex "set pagination off"` | Evita que salidas largas como `lx-ps` se corten |
| `-ex "target remote 127.0.0.1:1234"` | Se conecta al puerto serie de KGDB |
| `vmlinux` | El archivo con símbolos que gdb usa para traducir direcciones a nombres |

### `demo/nice.sh`
Dos bucles infinitos en la misma CPU con distinto nice.

| Línea | Para qué |
| --- | --- |
| `taskset -c 0 nice -n 0 sh -c 'while :; do :; done' &` | Proceso A: CPU 0, nice 0, solo calcula |
| `taskset -c 0 nice -n 5 ...` | Proceso B: CPU 0, nice 5. `taskset` fuerza que compitan en la misma runqueue |
| `sleep 5; top -b -n 1` | Deja correr 5 s y muestra el % de CPU |
| `grep -E 'se.vruntime\|se.sum_exec_runtime\|se.load.weight\|^prio\|nr_switches' /proc/$p/sched` | Tiempo virtual, tiempo real, peso, prioridad y cambios de contexto |
| `kill $A $B` | Los procesos siguen corriendo; hay que matarlos a mano |

### `demo/rt.sh`
Pasa un proceso a tiempo real.

| Línea | Para qué |
| --- | --- |
| `sleep 1000 & P=$!` | Proceso víctima. Largo a propósito: el reloj sigue corriendo mientras el kernel está congelado en gdb |
| `chrt -p $P` | Política antes (`SCHED_OTHER`) |
| `chrt -f -p 50 $P` | Pide `SCHED_FIFO` prioridad 50 → syscall `sched_setscheduler` → `__sched_setscheduler` (breakpoint) |
| `chrt -p $P` / `grep ... /proc/$P/sched` | Política y prio después (`policy 1`, `prio 49`) |
| `kill $P` | Limpieza |

### `demo/fork.sh`
Crea un proceso hijo.

| Línea | Para qué |
| --- | --- |
| `echo "Padre PID $$"` | PID del shell que ejecuta el script |
| `sh -c 'echo "Hijo PID $$, padre $PPID"'` | Lanza un hijo → `fork/clone` → `copy_process` → `wake_up_new_task` (breakpoint) |

---

## Guion de la demo

Dos terminales en `lab/`: **izquierda = VM**, **derecha = gdb**.

### 1. Arrancar la VM (izquierda)
```bash
./04-arrancar-vm.sh
```
Aparece el menú de demos y el prompt `/ #`.

### 2. Experimento 1: nice (solo VM)
```sh
/demo/nice.sh
kill <PID_A> <PID_B>     # los PID que imprime el script
```

### 3. Congelar el kernel (VM)
```sh
echo g > /proc/sysrq-trigger
```
Aparece `[0]kdb>` o `[1]kdb>`. **No escribas nada más en la VM.**

### 4. Conectar gdb (derecha)
```bash
./05-conectar-gdb.sh
```
Aparece `kgdb_breakpoint () at ...` y `(gdb)`. Opcional: `lx-ps` para listar las tasks.

### 5. Experimento 2: tiempo real
En gdb (los `break` **antes** de `continue`):
```
break __sched_setscheduler
continue
```
En la VM: `/demo/rt.sh`. El kernel se congela y gdb muestra `Breakpoint 1, __sched_setscheduler (...)`.

En gdb:
```
bt
p p->comm            # "sleep"
p p->policy          # 0  (SCHED_NORMAL)
p p->prio            # 120 (nice 0)
p *attr              # sched_policy = 1, sched_priority = 50
finish               # ejecuta la función hasta que retorna
p p->policy          # 1  (SCHED_FIFO)
p p->prio            # 49 (= 99 - 50)
p p->sched_class     # <rt_sched_class>
delete               # responder y
continue
```

### 6. Experimento 3: nace un proceso
En la VM, para recuperar el control en gdb: `echo g > /proc/sysrq-trigger` (gdb muestra `SIGTRAP`).

En gdb:
```
break wake_up_new_task
continue
```
En la VM: `/demo/fork.sh`.

En gdb:
```
bt
p p->pid             # el PID del "Padre" que imprimió el script
p p->se.vruntime     # 0: aún no ha entrado a la runqueue
finish
p p->se.vruntime     # número grande: se coloca cerca del vruntime promedio de la runqueue
p p->se.deadline     # ≈ vruntime + 700000 (medio slice)
p p->se.slice        # 1400000 (1,4 ms)
p p->sched_class     # <fair_sched_class>
delete
continue
```

### 7. Terminar
1. **Primero** en la VM: `Ctrl+A`, soltar, `X` (cierra QEMU).
2. **Después** en gdb: `quit`.

> Si gdb está en `Continuing.` no acepta comandos; cerrar QEMU antes hace que gdb recupere el prompt.

---

## Resultados obtenidos

| Experimento | Resultado | Esperado |
| --- | --- | --- |
| nice: tiempo real (`sum_exec_runtime`) | 3855 ms / 1262 ms = 75,3 % / 24,7 % | 75 % / 25 % ✅ |
| nice: `vruntime` | 4391 / 4396 | casi iguales ✅ |
| nice: `nr_switches` | 908 / 903 | parecidos: nice 0 no tiene turnos más largos, es elegido más veces seguidas ✅ |
| rt: antes | `sleep`, policy 0, prio 120 | ✅ |
| rt: pedido | policy 1, priority 50 | ✅ |
| rt: después | policy 1, prio 49, `rt_sched_class` | ✅ |
| fork: antes | `vruntime` 0 | ✅ |
| fork: después | `vruntime` ≈ 34,7 s, deadline +700000, slice 1400000, `fair_sched_class` | ✅ |

---

## Problemas conocidos y soluciones

| Síntoma | Causa | Solución |
| --- | --- | --- |
| Los breakpoints nunca se activan | Se escribió `continue` antes de `break`; con el kernel corriendo gdb no acepta comandos | Poner los `break` primero y luego `continue` |
| `hbreak` no se dispara | Los breakpoints por hardware no funcionan bajo KVM en este montaje | Usar `break` (software) |
| `rt.sh` termina con "No such process" | El reloj sigue avanzando mientras el kernel está congelado y el `sleep` corto termina | Ya corregido: `sleep 1000` |
| `lx-ps` se detiene a la mitad | Paginación de gdb | Ya corregido: `set pagination off` en `05` |
| `quit` no responde en gdb | gdb está en `Continuing.` | Cerrar QEMU primero (`Ctrl+A X`) |
| La VM no arranca (kernel panic al ejecutar `/init`) | `/init` con `#!/bin/sh`, que aún no existe | Ya corregido: `#!/bin/busybox sh` |
| Cambié una demo y no se ve en la VM | El initramfs es una copia | Ejecutar `./03-crear-initramfs.sh` |
| `Address already in use` en el puerto 1234 | Hay otra VM abierta | Cerrarla con `Ctrl+A X` o `pkill qemu-system` |

Mensajes normales en gdb: `New Thread` / `Thread exited`, números de hilo que no son PID, `received signal SIGTRAP` tras `sysrq g`, `Value returned is 0` después de `finish`, y avisos de `clocksource` en la VM tras estar congelada.

---

## Referencia rápida de comandos

**En la VM**
| Comando | Qué hace |
| --- | --- |
| `/demo/nice.sh`, `/demo/rt.sh`, `/demo/fork.sh` | Las demos |
| `echo g > /proc/sysrq-trigger` | Congela el kernel y entrega el control a KGDB |
| `cat /proc/<pid>/sched` | Estadísticas del scheduler de un proceso |
| `chrt -p <pid>` | Política y prioridad de tiempo real |
| `dmesg` | Mensajes de arranque del kernel |
| `poweroff -f` o `Ctrl+A X` | Apagar |

**En gdb**
| Comando | Qué hace |
| --- | --- |
| `break <función>` | Breakpoint de software |
| `continue` / `c` | Suelta el kernel |
| `bt` | Pila de llamadas |
| `p <expr>` | Imprime una variable o campo (`p p->se.vruntime`) |
| `finish` | Ejecuta hasta que la función actual retorna |
| `delete` | Borra todos los breakpoints |
| `lx-ps` | Lista las tasks del kernel |
| `lx-dmesg` | Log del kernel |
| `quit` | Salir |

**Funciones del scheduler interesantes para breakpoints**: `__schedule`, `pick_next_task_fair`, `update_curr`, `set_user_nice`, `set_load_weight`, `__sched_setscheduler`, `copy_process`, `wake_up_new_task`, `try_to_wake_up`.

---

## Archivos relacionados

- `Guía de estudio Scheduler de Linux y KGDB.pdf`: teoría completa (procesos, clases, EEVDF con ejemplo numérico, preemption, SMP, KGDB, preguntas probables y glosario).
- Código del scheduler en el kernel: `kernel/sched/core.c`, `kernel/sched/fair.c`, `kernel/sched/rt.c`, `include/linux/sched.h`.
