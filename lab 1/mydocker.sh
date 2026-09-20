#!/bin/bash

#пункт 3.1
sudo mkdir -p "/sys/fs/cgroup/lab 1"
echo 100M | sudo tee "/sys/fs/cgroup/lab 1/memory.max"
echo 0 | sudo tee "/sys/fs/cgroup/lab 1/memory.swap.max"
#Пункт 3.2
echo "50000 100000" | sudo tee "/sys/fs/cgroup/lab 1/cpu.max"

# Пункт 3.3
echo 20 | sudo tee "/sys/fs/cgroup/lab 1/pids.max"
echo $(pgrep -x api) | sudo tee "/sys/fs/cgroup/lab 1/cgroup.procs"
