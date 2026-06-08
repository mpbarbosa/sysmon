#!/usr/bin/env bash
set -euo pipefail

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
prev_idle=$((idle + iowait))
prev_total=$((user + nice + system + idle + iowait + irq + softirq + steal))

sleep 0.2

read -r _ user nice system idle iowait irq softirq steal _ < /proc/stat
idle_now=$((idle + iowait))
total_now=$((user + nice + system + idle + iowait + irq + softirq + steal))

delta_idle=$((idle_now - prev_idle))
delta_total=$((total_now - prev_total))

if [ "$delta_total" -le 0 ]; then
  cpu_usage="0.00"
else
  cpu_usage=$(awk -v idle="$delta_idle" -v total="$delta_total" 'BEGIN { printf "%.2f", (1 - idle / total) * 100 }')
fi

mem_total_kb=$(awk '/^MemTotal:/ { print $2 }' /proc/meminfo)
mem_available_kb=$(awk '/^MemAvailable:/ { print $2 }' /proc/meminfo)
mem_used_percent=$(awk -v total="$mem_total_kb" -v avail="$mem_available_kb" 'BEGIN { if (total <= 0) { print "0.00" } else { printf "%.2f", ((total - avail) / total) * 100 } }')

printf '{"cpu":%s,"memory":%s}\n' "$cpu_usage" "$mem_used_percent"
