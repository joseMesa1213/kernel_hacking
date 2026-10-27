#!/bin/sh
# Crea un proceso hijo. Con breakpoints en copy_process / wake_up_new_task, KGDB se detiene aqui.
echo "Padre PID $$"
sh -c 'echo "Hijo PID $$, padre $PPID"'
