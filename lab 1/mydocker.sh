#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export API="$SCRIPT_DIR/api/api"

CGROUP=/sys/fs/cgroup/mydocker
#пункт 3.1
sudo mkdir -p "$CGROUP"
echo 100M | sudo tee "$CGROUP/memory.max"
echo 0    | sudo tee "$CGROUP/memory.swap.max"
#Пункт 3.2
echo "50000 100000" | sudo tee "$CGROUP/cpu.max"
# Пункт 3.3
echo 20   | sudo tee "$CGROUP/pids.max"
echo $$   | sudo tee "$CGROUP/cgroup.procs"

# Пункт 2
# 2 пункт располгается после 3, потому что exec unshare заменяет текущий процесс, и все последующие команды не будут выполнены.
exec unshare --pid --mount --net --uts --ipc --user --map-root-user --fork \
    sh -c '
        umount /proc 2>/dev/null
        mount -t proc proc /proc    
        ip link set lo up
        exec "$API"
    '