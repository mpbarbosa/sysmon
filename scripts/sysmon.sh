#!/usr/bin/env bash
set -euo pipefail

if [[ ! -r /proc/stat || ! -r /proc/meminfo ]]; then
  printf '{"cpu":0.00,"memory":0.00}\n'
  exit 0
fi

if ! read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat; then
  printf '{"cpu":0.00,"memory":0.00}\n'
  exit 0
fi
prev_idle=$((idle + iowait))
prev_total=$((user + nice + system + idle + iowait + irq + softirq + steal))

sleep 0.1

if ! read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat; then
  printf '{"cpu":0.00,"memory":0.00}\n'
  exit 0
fi
idle_now=$((idle + iowait))
total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))

delta_idle=$((idle_now - prev_idle))
delta_total=$((total_now - prev_total))

if [ "$delta_total" -le 0 ]; then
  cpu_usage="0.00"
else
  cpu_usage=$(awk -v idle="$delta_idle" -v total="$delta_total" 'BEGIN { printf "%.2f", (1 - idle / total) * 100 }')
fi

read -r mem_total_kb mem_available_kb < <(awk '
  /^MemTotal:/ { total = $2 }
  /^MemAvailable:/ { available = $2 }
  /^MemFree:/ { free = $2 }
  /^Buffers:/ { buffers = $2 }
  /^Cached:/ { cached = $2 }
  END {
    if (available == "") {
      available = free + buffers + cached
    }

    printf "%s %s\n", total, available
  }
' /proc/meminfo)
mem_used_percent=$(awk -v total="$mem_total_kb" -v avail="$mem_available_kb" 'BEGIN { if (total <= 0) { print "0.00" } else { printf "%.2f", ((total - avail) / total) * 100 } }')

printf '{"cpu":%s,"memory":%s}\n' "$cpu_usage" "$mem_used_percent"
