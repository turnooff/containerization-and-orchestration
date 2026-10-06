#!/usr/bin/env bash
# cgroup-exporter.sh — выгружает метрики cgroup v2 в формате Prometheus textfile.
#
# Использование:
#   CGROUP_PATH=/sys/fs/cgroup/mydocker \
#   OUTPUT=/path/to/textfile/mydocker.prom \
#   INTERVAL=15 \
#   ./cgroup-exporter.sh
#
# Остановка: Ctrl-C (SIGINT/SIGTERM).

set -u

export LC_ALL=C

set -o pipefail
# set -e НЕ ставим: скрипт — daemon-цикл, падать от первой неудачи нельзя.

# Директория скрипта — чтобы OUTPUT по умолчанию не зависел от cwd.
# Скрипт могут запустить откуда угодно, а файл должен лечь рядом с textfile/.
SCRIPT_DIR="$(cd "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"

CGROUP_PATH="${CGROUP_PATH:-/sys/fs/cgroup/mydocker}"
OUTPUT="${OUTPUT:-$SCRIPT_DIR/textfile/mydocker.prom}"
INTERVAL="${INTERVAL:-15}"

OUTPUT_DIR="$(dirname -- "$OUTPUT")"
TMP_FILE="$OUTPUT_DIR/.mydocker.prom.tmp.$$"

# Файл читает node_exporter под другим UID — он должен быть world-readable.
umask 022

log() {
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2
}

cleanup() {
    rm -f -- "$TMP_FILE"
}
# EXIT-трап срабатывает и при INT/TERM, отдельные ловушки не нужны.
trap cleanup EXIT

# ---------------------------------------------------------------------------
# Хелперы
# ---------------------------------------------------------------------------

# read_trim <file> — первая строка без \n\r. Пусто, если файла нет.
read_trim() {
    local f="$1"
    [ -r "$f" ] || { printf ''; return 0; }
    tr -d '\n\r' < "$f"
}

# read_key <file> <key> — значение ключа из файла вида "key value\n".
read_key() {
    local f="$1" key="$2"
    [ -r "$f" ] || { printf ''; return 0; }
    awk -v k="$key" '$1 == k { print $2; exit }' "$f" 2>/dev/null
}

# num_or_default <value> <default> — не число/пусто → default.
num_or_default() {
    local v="$1" d="$2"
    if [ -z "$v" ] || ! [[ "$v" =~ ^-?[0-9]+([.][0-9]+)?$ ]]; then
        printf '%s' "$d"
    else
        printf '%s' "$v"
    fi
}

# usec_to_sec <usec> — целое микросекунд → секунды с 6 знаками.
usec_to_sec() {
    local usec="$1"
    [ -z "$usec" ] && { printf '0'; return 0; }
    awk -v u="$usec" 'BEGIN { printf "%.6f", u / 1000000 }'
}

# ---------------------------------------------------------------------------
# Сбор
# ---------------------------------------------------------------------------

collect_and_write() {
    local mem_current mem_max mem_max_line
    local cpu_usage_usec cpu_usage_sec
    local nr_periods nr_throttled throttled_usec throttled_sec
    local pids oom_kill

    # --- memory.current ---
    mem_current="$(num_or_default "$(read_trim "$CGROUP_PATH/memory.current")" 0)"

    # --- memory.max ---
    # В cgroup v2 здесь либо число, либо строка "max" (лимита нет).
    # Если лимита нет — не отдаём метрику, иначе current/max даёт +Inf
    # и любой алерт "usage > 80%" сработает ложно.
    mem_max="$(read_trim "$CGROUP_PATH/memory.max")"
    mem_max_line=""
    if [ "$mem_max" != "max" ] && [ -n "$mem_max" ]; then
        mem_max_line="$(num_or_default "$mem_max" 0)"
    fi

    # --- cpu.stat ---
    cpu_usage_usec="$(num_or_default "$(read_key "$CGROUP_PATH/cpu.stat" usage_usec)" 0)"
    nr_periods="$(num_or_default "$(read_key "$CGROUP_PATH/cpu.stat" nr_periods)" 0)"
    nr_throttled="$(num_or_default "$(read_key "$CGROUP_PATH/cpu.stat" nr_throttled)" 0)"
    throttled_usec="$(num_or_default "$(read_key "$CGROUP_PATH/cpu.stat" throttled_usec)" 0)"
    cpu_usage_sec="$(usec_to_sec "$cpu_usage_usec")"
    throttled_sec="$(usec_to_sec "$throttled_usec")"

    # --- pids.current ---
    pids="$(num_or_default "$(read_trim "$CGROUP_PATH/pids.current")" 0)"

    # --- memory.events ---
    oom_kill="$(num_or_default "$(read_key "$CGROUP_PATH/memory.events" oom_kill)" 0)"

    # --- запись во временный файл, потом атомарный mv ---
    {
        printf '%s\n' "# HELP mydocker_memory_current_bytes Current memory usage"
        printf '%s\n' "# TYPE mydocker_memory_current_bytes gauge"
        printf 'mydocker_memory_current_bytes %s\n' "$mem_current"

        if [ -n "$mem_max_line" ]; then
            printf '\n'
            printf '%s\n' "# HELP mydocker_memory_max_bytes Memory limit"
            printf '%s\n' "# TYPE mydocker_memory_max_bytes gauge"
            printf 'mydocker_memory_max_bytes %s\n' "$mem_max_line"
        fi

        printf '\n'
        printf '%s\n' "# HELP mydocker_cpu_usage_seconds_total CPU usage in seconds"
        printf '%s\n' "# TYPE mydocker_cpu_usage_seconds_total counter"
        printf 'mydocker_cpu_usage_seconds_total %s\n' "$cpu_usage_sec"

        printf '\n'
        printf '%s\n' "# HELP mydocker_cpu_periods_total CPU periods"
        printf '%s\n' "# TYPE mydocker_cpu_periods_total counter"
        printf 'mydocker_cpu_periods_total %s\n' "$nr_periods"

        printf '\n'
        printf '%s\n' "# HELP mydocker_cpu_throttled_periods_total Throttled periods"
        printf '%s\n' "# TYPE mydocker_cpu_throttled_periods_total counter"
        printf 'mydocker_cpu_throttled_periods_total %s\n' "$nr_throttled"

        printf '\n'
        printf '%s\n' "# HELP mydocker_cpu_throttled_seconds_total Time throttled, seconds"
        printf '%s\n' "# TYPE mydocker_cpu_throttled_seconds_total counter"
        printf 'mydocker_cpu_throttled_seconds_total %s\n' "$throttled_sec"

        printf '\n'
        printf '%s\n' "# HELP mydocker_pids_current Current PIDs"
        printf '%s\n' "# TYPE mydocker_pids_current gauge"
        printf 'mydocker_pids_current %s\n' "$pids"

        printf '\n'
        printf '%s\n' "# HELP mydocker_memory_oom_kills_total OOM kills"
        printf '%s\n' "# TYPE mydocker_memory_oom_kills_total counter"
        printf 'mydocker_memory_oom_kills_total %s\n' "$oom_kill"
    } > "$TMP_FILE"

    mv -f -- "$TMP_FILE" "$OUTPUT"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ ! -d "$CGROUP_PATH" ]; then
    log "warning: cgroup path '$CGROUP_PATH' does not exist yet — will retry"
fi

if [ ! -d "$OUTPUT_DIR" ]; then
    log "info: creating output dir '$OUTPUT_DIR'"
    mkdir -p -- "$OUTPUT_DIR" || {
        log "error: cannot create output dir"
        exit 1
    }
fi

log "started: cgroup=$CGROUP_PATH output=$OUTPUT interval=${INTERVAL}s"

while true; do
    if ! collect_and_write; then
        log "warn: collect failed, will retry"
    fi
    sleep "$INTERVAL"
done