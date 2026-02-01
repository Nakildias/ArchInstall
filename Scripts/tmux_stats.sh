#!/bin/bash
# Tmux Native Status Bar Stats Script
# Called every second by tmux

TEMP_FILE="/tmp/archinstall_stats.tmp"

# --- Functions ---

get_cpu() {
    read -r cpu user nice system idle iowait irq softirq steal guest guest_nice < /proc/stat
    echo "$user $nice $system $idle $iowait $irq $softirq $steal"
}

get_rx_bytes() {
    local rx=0
    for rx_file in /sys/class/net/*/statistics/rx_bytes; do
        if [[ "$rx_file" != *"/lo/"* ]]; then
            val=$(cat "$rx_file" 2>/dev/null || echo 0)
            rx=$((rx + val))
        fi
    done
    echo "$rx"
}

# --- Main Logic ---

# 1. Get Current Readings
read -r c_user c_nice c_system c_idle c_iowait c_irq c_softirq c_steal <<< "$(get_cpu)"
current_rx=$(get_rx_bytes)
current_time=$(date +"%H:%M:%S")

# 2. Read Previous State (if exists)
if [[ -f "$TEMP_FILE" ]]; then
    source "$TEMP_FILE"
else
    # First run, initialize with current values to avoid massive spikes/errors
    prev_user=$c_user
    prev_nice=$c_nice
    prev_system=$c_system
    prev_idle=$c_idle
    prev_iowait=$c_iowait
    prev_irq=$c_irq
    prev_softirq=$c_softirq
    prev_steal=$c_steal
    prev_rx=$current_rx
fi

# 3. Calculate CPU
# Total = Sum of all fields
prev_total=$((prev_user + prev_nice + prev_system + prev_idle + prev_iowait + prev_irq + prev_softirq + prev_steal))
curr_total=$((c_user + c_nice + c_system + c_idle + c_iowait + c_irq + c_softirq + c_steal))

# Idle = idle + iowait
prev_idle_sum=$((prev_idle + prev_iowait))
curr_idle_sum=$((c_idle + c_iowait))

total_diff=$((curr_total - prev_total))
idle_diff=$((curr_idle_sum - prev_idle_sum))

cpu_usage=0
if [ "$total_diff" -gt 0 ]; then
    cpu_usage=$((100 * (total_diff - idle_diff) / total_diff))
fi

# 4. Calculate Network
rx_diff=$((current_rx - prev_rx))
# Mbps
net_speed=$(awk -v b="$rx_diff" 'BEGIN { printf "%.2f", (b * 8) / 1000000 }')

# 5. Get RAM
ram_usage=$(free -h | awk '/^Mem:/ {print $3 "/" $2}')

# 6. IPv4
ip_addr=$(ip route get 1.1.1.1 2>/dev/null | awk '{print $7; exit}')

# 7. Save Current State for Next Run
cat <<EOF > "$TEMP_FILE"
prev_user=$c_user
prev_nice=$c_nice
prev_system=$c_system
prev_idle=$c_idle
prev_iowait=$c_iowait
prev_irq=$c_irq
prev_softirq=$c_softirq
prev_steal=$c_steal
prev_rx=$current_rx
EOF

# 8. Output Formatted String for Tmux
# Icons/Styles handled by tmux config mostly, but we produce the raw text here.
echo "CPU: ${cpu_usage}% | RAM: ${ram_usage} | DL: ${net_speed}Mbps | IP: ${ip_addr} | ${current_time} "
