#!/bin/sh
# Pasa un proceso a SCHED_FIFO prioridad 50.
# Con un breakpoint en __sched_setscheduler, KGDB se detiene aqui.
# sleep largo: mientras el kernel esta congelado el reloj sigue avanzando,
# y un sleep corto terminaria antes de poder mostrar el "Despues".
sleep 1000 & P=$!
echo "Antes:"; chrt -p $P
chrt -f -p 50 $P
echo "Despues:"; chrt -p $P
grep -E '^policy|^prio' /proc/$P/sched
kill $P
