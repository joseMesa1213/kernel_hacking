#!/bin/sh
# Dos procesos que solo calculan, forzados a la CPU 0, con nice 0 y nice 5.
# Esperado: ~75% y ~25% de CPU, pero vruntime casi igual.
taskset -c 0 nice -n 0 sh -c 'while :; do :; done' & A=$!
taskset -c 0 nice -n 5 sh -c 'while :; do :; done' & B=$!
echo "A (nice 0) = PID $A    B (nice 5) = PID $B"
sleep 5
top -b -n 1 | head -n 12
for p in $A $B; do
  echo "--- PID $p ---"
  grep -E 'se.vruntime|se.sum_exec_runtime|se.load.weight|^prio|nr_switches' /proc/$p/sched
done
echo "Los procesos siguen corriendo. Para pararlos: kill $A $B"
