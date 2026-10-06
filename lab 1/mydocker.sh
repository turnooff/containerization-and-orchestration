#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

# По рофлу написано, чтобы проверить что api норм работает
check_api() {
    local attempt reply
    for attempt in {1..50}; do
        if [[ $(cat /proc/1/comm) == api ]]; then
            if reply=$(curl --noproxy '*' --silent --fail --max-time 1 \
                http://127.0.0.1:8080/health) && [[ $reply == ok ]]; then
                echo "ПРОВЕРКА: /health возвращает ok, API работает как PID 1"
                if awk '''
                    /^Cap(Inh|Prm|Eff|Bnd|Amb):/ {
                        caps++; if ($2 !~ /^0+$/) bad=1
                    }
                    /^NoNewPrivs:/ { nnp=($2 == 1) }
                    /^Seccomp:/ { seccomp=($2 == 2) }
                    END { exit !(caps == 5 && !bad && nnp && seccomp) }
                ''' /proc/1/status; then
                    echo "ПРОВЕРКА: capabilities API сброшены, NoNewPrivs=1, Seccomp=2"
                else
                    echo "ОШИБКА ПРОВЕРКИ: права API не соответствуют ожидаемым" >&2
                    return 1
                fi
                return 0
            fi
        fi
        sleep 0.1
    done
    echo "ОШИБКА ПРОВЕРКИ: API не ответил ok за время ожидания" >&2
    return 1
}
export -f check_api
command -v curl >/dev/null

# Часть 3 — cgroups: создаём группу для запускаемых процессов.
CGROUP="/sys/fs/cgroup/mydocker"
sudo mkdir -p "$CGROUP"

for name in memory.max memory.swap.max cpu.max pids.max; do
    if [ ! -f "$CGROUP/$name" ]; then
        echo "Нет файла $CGROUP/$name" >&2
        exit 1
    fi
done


# Пункт 3.1 — ограничиваем память и запрещаем swap.
echo 100M | sudo tee "$CGROUP/memory.max"
echo 0 | sudo tee "$CGROUP/memory.swap.max"
# Пункт 3.2 — 50 мс процессорного времени на каждые 100 мс.
echo "50000 100000" | sudo tee "$CGROUP/cpu.max"
# Пункт 3.3 — ограничиваем число задач, включая потоки.
echo 20 | sudo tee "$CGROUP/pids.max"

# Помещаем процесс скрипта в cgroup: новые потомки унаследуют её.
echo "$$" | sudo tee "$CGROUP/cgroup.procs"

# Часть 2 — namespaces. Сначала подготовили cgroup, теперь создаём окружение.
# В конце внутренней оболочки exec заменит её на API с сохранением PID 1.
unshare --pid --mount --net --uts --ipc --user \
    --map-root-user --mount-proc --fork bash -c '
    set -euo pipefail

    #имя хоста
    hostname love-frogs

    #Настройка сети
    ip link set lo up

    # Проверка ждёт запуска API; основной процесс затем заменится сервисом.
    check_api &

    # Часть 4 — capabilities, seccomp и заодно проверка запретов.
    exec setpriv \
    --bounding-set=-all \
    --inh-caps=-all \
    --ambient-caps=-all \
    --no-new-privs \
    ./seccomp-launcher bash -c "
    if hostname should-not-work; then
        echo \"ОШИБКА: удалось изменить hostname\"
        exit 1
    else
        echo \"Смена hostname запрещена\"
    fi

    if mkdir -- \"\$1\"; then
        echo \"ОШИБКА: удалось создать каталог\"
        rmdir -- \"\$1\"
        exit 1
    else
        echo \"Создание каталога запрещено\"
    fi

    exec ./api/api
" bash "$PWD/seccomp-check-$$"
'
