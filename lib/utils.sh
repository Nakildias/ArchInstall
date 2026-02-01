#!/bin/bash

# --- Helper Functions ---

# --- Colors & Styles ---
C_BOLD="\e[1m"
C_OFF="\e[0m"

# Format bytes to human readable
format_bytes() {
    local bytes=$1
    if [[ $bytes -lt 1024 ]]; then
        echo "${bytes} B"
    elif [[ $bytes -lt 1048576 ]]; then
        echo "$(( (bytes + 512) / 1024 )) KiB"
    elif [[ $bytes -lt 1073741824 ]]; then
        echo "$(( (bytes + 524288) / 1048576 )) MiB"
    else
        awk "BEGIN {printf \"%.2f GiB\", $bytes/1073741824}"
    fi
}


# Colors (Strict Palette)
C_WHITE="\e[1;37m"   # Headers
C_BLUE="\e[1;34m"    # Actions (::)
C_CYAN="\e[1;36m"    # Info / Context
C_GREEN="\e[1;32m"   # Success / Safe
C_YELLOW="\e[1;33m"  # Warnings / Prompts
C_RED="\e[1;31m"     # Errors
C_GREY="\e[0;90m"    # Sub-text / Details

# --- Visual Primitives ---

# Header: Bold, Capitalized, with Separator
# Usage: print_header "DISK CONFIGURATION"
print_header() {
    local title="${1^^}" # Uppercase
    echo -e "\n${C_WHITE}${C_BOLD}------------------------------------------------------------${C_OFF}"
    echo -e "${C_WHITE}${C_BOLD}  ${title}${C_OFF}"
    echo -e "${C_WHITE}${C_BOLD}------------------------------------------------------------${C_OFF}"
}

# Action Item: The primary linear step indicator
# Usage: print_action "Scanning for devices..."
print_action() {
    # Format: :: Scanning for devices...
    echo -e "${C_BLUE}${C_BOLD}::${C_OFF} ${C_BOLD}${1}${C_OFF}"
    log_to_file "ACTION: $1"
}

# Sub Item: Details or results
# Usage: print_subitem "Found /dev/sda"
print_subitem() {
    # Format:    -> Found /dev/sda
    echo -e "   ${C_GREY}-> ${1}${C_OFF}"
    log_to_file "DETAIL: $1"
}

# Context/Help Text: Explanatory text block
# Usage: print_context "This feature allows you to..."
print_context() {
    # Indented, Cyan or Grey
    echo -e "${C_CYAN}   ${1}${C_OFF}"
}

# --- Status & Logging ---

check_dependencies() {
    local dependencies=("curl" "lsblk" "sgdisk" "mkfs.ext4" "mkfs.btrfs" "mkfs.xfs" "mkfs.fat" "mkswap" "wipefs" "mount" "umount" "pacstrap" "genfstab" "arch-chroot" "sed" "grep" "awk" "cryptsetup" "dmsetup" "lspci" "tmux")
    local missing_deps=()

    for dep in "${dependencies[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            missing_deps+=("$dep")
        fi
    done

    if [ ${#missing_deps[@]} -ne 0 ]; then
        echo -e "${C_RED}${C_BOLD}[ERROR]${C_OFF} Missing required dependencies: ${missing_deps[*]}"
        echo "Please install them and try again."
        exit 1
    fi
}

log_to_file() {
    local log_file="${LOG_FILE:-}"
    if [[ -z "$log_file" ]]; then return; fi
    # Strip ANSI codes for log
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$log_file"
}

# Standardized "Info" -> Mapped to Action or Subitem depending on context? 
# For backward compatibility with existing calls, let's map 'info' to 'print_action'
# BUT, if it's used for minor details, it might be too bold. 
# Let's check usage. Ideally we should refactor calls, but for now:
info() {
    print_action "$1"
    update_status "$1"
}

warn() {
    echo -e "${C_YELLOW}${C_BOLD}:: [WARNING]${C_OFF} ${1}"
    log_to_file "WARN: $1"
    update_status "WARNING: $1"
}

error() {
    echo -e "${C_RED}${C_BOLD}:: [ERROR]${C_OFF} ${C_BOLD}${1}${C_OFF}"
    log_to_file "ERROR: $1"
    update_status "ERROR: $1"
}

success() {
    echo -e "${C_GREEN}${C_BOLD}:: [SUCCESS]${C_OFF} ${1}"
    log_to_file "SUCCESS: $1"
    update_status "$1"
}

# Update Status Bar - Prints to the bottom line (Simple replacement)
update_status() {
    # Deprecated: Status is now handled by tmux
    :
}

# --- Quiet Execution with Spinner ---

# Usage: run_quiet "Installing Base System" pacstrap -K /mnt base ...
run_quiet() {
    local desc="$1"
    shift

    print_action "$desc"

    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        # Verbose: Print Header and Stream Output (while logging)
        "$@" 2>&1 | tee -a "$LOG_FILE"
        local exit_code=${PIPESTATUS[0]}
        
        if [ $exit_code -eq 0 ]; then
            print_subitem "${C_GREEN}Done.${C_OFF}"
            return 0
        else
            error "Command failed: $*"
            return $exit_code
        fi
    else
        # Quiet Mode with Dynamic Progress
        # Run command in background, redirecting all output to log
        "$@" >> "$LOG_FILE" 2>&1 &
        local pid=$!
        
        # Hide cursor
        tput civis

        # Loop while process is running
        while kill -0 "$pid" 2>/dev/null; do
            # Get last line of log, truncate to 70 chars to fit most screens
            local last_line
            last_line=$(tail -n 1 "$LOG_FILE" 2>/dev/null | cut -c 1-70)
            
            # Print overwriting the line (carriage return \r)
            # \e[K clears to end of line
            echo -ne "   :: ${C_GREY}${last_line}\e[K\r${C_OFF}"
            
            sleep 0.5
        done
        
        # Restore cursor and clear the progress line
        tput cnorm
        echo -ne "\e[K\r" 

        # Capture exit code
        wait "$pid"
        local status=$?

        if [ $status -eq 0 ]; then
             log_to_file "SUCCESS: $desc"
             print_subitem "${C_GREEN}Done.${C_OFF}"
        else
             log_to_file "FAILURE: $desc (Exit Code: $status)"
             error "Failed: $desc. See $LOG_FILE for details."
             print_subitem "${C_RED}failed${C_OFF}"
             exit 1
        fi
    fi
}

# Helper for commands that are usually silent (like wipefs, sgdisk)
# Usage: exec_silent command args...
exec_silent() {
    if [[ "${VERBOSE_MODE:-false}" == "true" ]]; then
        "$@" 2>&1 | tee -a "$LOG_FILE"
    else
        "$@" >> "$LOG_FILE" 2>&1
    fi
}

# --- Prompts ---

# Replaces standard prompt
prompt() {
    local label="$1"
    local var_name="$2"
    
    # Trim trailing whitespace from label to avoid double spaces
    # (e.g. "Enter name: " -> "Enter name:")
    local clean_label
    clean_label=$(echo "$label" | sed 's/[[:space:]]*$//')

    # Use -ne to print without newline, allowing input on the same line
    # We explicitly add ONE space here.
    echo -ne "${C_YELLOW}${C_BOLD}   > ${clean_label}${C_OFF} "
    read -r "$var_name"
    log_to_file "INPUT: $label -> ${!var_name}"
}

# Confirmation
confirm() {
    local label="$1"
    while true; do
        echo -e "${C_YELLOW}${C_BOLD}   > ${label} [y/N]:${C_OFF} \c"
        read -r yn
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;; # Default No
            *) echo -e "     ${C_RED}Please answer yes or no.${C_OFF}" ;;
        esac
    done
}

get_password() {
    local user_label="$1"
    local config_var_name="$2"
    local pass_val
    local pass_confirm

    print_action "Setting password for ${user_label}."
    while true; do
        echo -ne "${C_YELLOW}${C_BOLD}   > Enter password for ${user_label}: ${C_OFF}"
        read -rsp "" pass_val
        echo
        echo -ne "${C_YELLOW}${C_BOLD}   > Confirm password for ${user_label}: ${C_OFF}"
        read -rsp "" pass_confirm
        echo

        if [[ -z "$pass_val" ]]; then
            echo -e "     ${C_RED}Password cannot be empty.${C_OFF}"
            continue
        fi

        if [[ "$pass_val" == "$pass_confirm" ]]; then
            print_subitem "Password confirmed."
            printf -v "$config_var_name" "%s" "$pass_val"
            break
        else
            echo -e "     ${C_RED}Passwords do not match.${C_OFF}"
        fi
    done
}

# --- Summary "Receipt" ---

show_summary() {
    print_header "CONFIGURATION SUMMARY"
    echo -e "${C_WHITE}Review the following settings before proceeding:${C_OFF}"
    echo "--------------------------------------------------"
    
    # helper for keys - uses %b to interpret escape sequences in values
    print_key_val() {
        local key="$1"
        local val="$2"
        # Printf: Key (Left aligned 22), Separator, Value
        # %b interprets backslash escapes in the value (for colors)
        printf "  ${C_GREY}%-22s${C_OFF} : ${C_BOLD}%b${C_OFF}\n" "$key" "$val"
    }
    
    # helper for boolean display
    print_bool() {
        local key="$1"
        local val="$2"
        local text="Disabled"
        if [[ "$val" == "true" ]]; then text="${C_GREEN}Enabled${C_OFF}"; fi
        print_key_val "$key" "$text"
    }

    # --- Context ---
    print_key_val "Config Profile" "$(basename "${CONFIG_FILE:-Interactive (None)}")"
    print_key_val "Boot Mode" "${BOOT_MODE}"
    echo ""
    
    # --- System ---
    print_key_val "Hostname" "${HOSTNAME}"
    print_key_val "Timezone" "${DEFAULT_REGION}/${DEFAULT_CITY}"
    print_key_val "Locale" "${SYSTEM_LOCALE:-en_US.UTF-8}"
    print_key_val "Keyboard Layout" "${SYSTEM_KEYMAP:-us}"
    
    local root_status="Disabled (Locked)"
    [ "${ENABLE_ROOT_ACCOUNT}" == "true" ] && root_status="Enabled"
    print_key_val "Root Account" "$root_status"
    
    local users_list="${USER_NAMES[*]}"
    print_key_val "User Accounts" "${users_list:-None}"
    echo ""

    # --- Disk & Swap ---
    print_key_val "Target Disk" "${TARGET_DISK} (${TARGET_DISK_SIZE})"
    print_key_val "Filesystem" "${SELECTED_FS}"
    
    local enc_status="Disabled"
    [ "${ENABLE_ENCRYPTION}" == "true" ] && enc_status="${C_GREEN}Enabled (LUKS)${C_OFF}"
    print_key_val "Encryption" "$enc_status"

    local swap_display="None"
    [[ "${SWAP_TYPE}" == "Partition" ]] && swap_display="Partition (${SWAP_PART_SIZE})"
    [[ "${SWAP_TYPE}" == "ZRAM" ]] && swap_display="ZRAM (Compressed RAM)"
    print_key_val "Swap" "$swap_display"
    echo ""

    # --- Environment ---
    print_key_val "Kernel" "${SELECTED_KERNEL}"
    print_key_val "Bootloader" "${SELECTED_BOOTLOADER}"
    print_key_val "GPU Driver" "$([ "${INSTALL_NVIDIA}" == "true" ] && echo "NVIDIA (Proprietary)" || echo "Standard (Open Source/Mesa)")"

    # Profile Name
    local profile_display="${DE_PRETTY_NAME:-$SELECTED_DE_NAME}"
    print_key_val "Profile" "${profile_display:-None}"
    
    local autologin_status="Disabled"
    [[ -n "${AUTO_LOGIN_USER:-}" ]] && autologin_status="Enabled (${AUTO_LOGIN_USER})"
    print_key_val "Auto-Login" "$autologin_status"

    if [[ -n "${SELECTED_THEME_FILE:-}" ]]; then
        print_key_val "KDE Theme" "$(basename "$SELECTED_THEME_FILE")"
    fi

    # TTY Ricing Status
    local tty_status="Standard"
    if [[ "${ENABLE_TTY_RICE:-}" == "true" ]]; then
        tty_status="${C_CYAN}High-Res KMSCON${C_OFF} (${TTY_RES:-Auto})"
        [[ -n "${TTY_THEME_ID:-}" ]] && tty_status="$tty_status [Theme Applied]"
    fi
    print_key_val "TTY Interface" "$tty_status"
    echo ""

    # --- Features & Extras ---
    print_bool "AUR Helper (Yay)" "${INSTALL_YAY:-false}"
    print_bool "Gaming (Steam)" "${INSTALL_STEAM:-false}"
    print_bool "Firewall (UFW)" "${INSTALL_UFW:-false}"
    print_bool "Zsh Shell" "${INSTALL_ZSH:-false}"
    
    # --- Network ---
    local mirror_status="Auto (Reflector)"
    [ "${USE_LOCAL_MIRROR}" == "true" ] && mirror_status="Local (${LOCAL_MIRROR_URL})"
    print_key_val "Mirror" "$mirror_status"
    print_key_val "Parallel Downloads" "${PARALLEL_DL_COUNT:-5}"
    
    echo "--------------------------------------------------"
    
    warn "This will ERASE ALL DATA on ${TARGET_DISK}."
    update_status "Final Verification: Ready to install?"
    confirm "Final check: Ready to install?" || { print_action "Installation cancelled by user."; exit 0; }

    # Start the timer after user confirmation
    START_TIME=$(date +%s)
}

# --- System Handlers ---

check_status() {
    local status=$?
    if [ $status -ne 0 ]; then
        error "Step failed: $1 (Exit Code: $status)"
        exit 1
    fi
}

setup_trap() {
    trap 'EXIT_CODE=$?; if [ $EXIT_CODE -ne 0 ]; then echo "FAILED COMMAND: $BASH_COMMAND"; echo "AT LINE: ${BASH_LINENO[0]}"; fi; printf "\033[r"; tput cnorm; cleanup $EXIT_CODE' EXIT SIGHUP SIGINT SIGTERM
}

cleanup() {
    local code=${1:-0}
    if [[ $$ -ne $BASHPID ]]; then return; fi
    
    if [[ "$INSTALL_SUCCESS" == "true" ]]; then
        tput cnorm
        return
    fi
    
    if [[ $code -eq 0 ]]; then
        # Normal exit (user quit)
        return
    fi
  
    # Error cleanup
    echo -e "\n${C_RED}${C_BOLD}:: Script Interrupted or Failed (Exit Code: $code).${C_OFF}"
    
    # Save log if possible
    if [[ -f "${LOG_FILE}" ]]; then
        cp "${LOG_FILE}" ./installer.logs
        echo -e "   ${C_GREY}-> Crash log saved to $(pwd)/installer.logs${C_OFF}"
        
        echo -e "\n${C_YELLOW}--- Last 20 Log Lines ---${C_OFF}"
        tail -n 20 "${LOG_FILE}"
        echo -e "${C_YELLOW}-------------------------${C_OFF}"
    fi
    
    echo -e "   ${C_GREY}-> Attempting cleanup unmount...${C_OFF}"
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
       swapoff "${SWAP_PARTITION}" &>/dev/null
    fi
    
    tput cnorm
    
    echo ""
    echo -e "${C_YELLOW}${C_BOLD}Press ENTER to exit...${C_OFF}"
    read -r
    exit $code
}

setup_environment() {
    # 1. TRAP ERRORS EARLY
    # This keeps the tmux window open if the script crashes so you can read the error.
    trap 'echo "Script failed. Press ENTER to close tmux..."; read' ERR

    # 2. THE HAND-OFF
    # Use ${TMUX:-} to safely check the variable even if set -u is active.
    if [[ -z "${TMUX:-}" ]]; then
        if ! command -v tmux >/dev/null 2>&1; then
            echo "Error: tmux is required but not installed."
            exit 1
        fi
        # Launch tmux and tell it to stay open after the script exits (-P and no exec)
        # This allows you to see the error message if it fails again.
        tmux new-session -s archinstall "bash $0 $@"
        exit 0
    fi

    # 3. ENVIRONMENT INITIALIZATION (Inside Tmux)
    # Give tmux a split second to initialize the pseudo-terminal
    sleep 0.5

    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit 1
    fi

    # Define the log file before enabling strict modes
    LOG_FILE="/var/log/archinstall.log"

    # Enable error handling but delay 'set -u'
    set -e
    set -o pipefail

    # Redirect stderr to log
    exec 2>>"$LOG_FILE"

    configure_tmux_status

    # Now that config.sh is sourced by install.sh, it's safe to enable set -u
    set -u

    print_header "ARCH LINUX INSTALLER v${SCRIPT_VERSION:-3.1}"
    print_subitem "Log: ${LOG_FILE}"

    tput cnorm
    setup_trap
}

run_with_retry() {
    # Wrapper for run_quiet or direct? 
    # Usually usage: run_with_retry cmd args...
    # We should adapt it to be quiet or verbose.
    # For now, let's keep it functional but use print_action for status.
    
    local max_retries=10
    local wait_time=5
    local count=0
    
    set +e 
    while [ $count -lt $max_retries ]; do
        "$@"
        local status=$?
        if [ $status -eq 0 ]; then
            set -e
            return 0
        fi
        
        count=$((count + 1))
        warn "Command failed (Attempt $count/$max_retries): $*"
        sleep $wait_time
    done
    error "Command failed permanently."
    exit 1
}

save_logs() {
    if [[ -f "${LOG_FILE}" ]]; then
        cp "${LOG_FILE}" ./installer.logs
        print_subitem "Crash/Install log saved to $(pwd)/installer.logs"
    fi
}

# Placeholder exit_menu wrapper if needed, or rely on install.sh

# --- Tmux Integration ---

ensure_tmux_environment() {
    # Check if we are already in tmux
    if [[ -z "${TMUX:-}" ]]; then
        print_action "Tmux not detected. Auto-starting tmux environment..."
        # Use exec to replace the current shell with a tmux session running this script
        exec tmux new-session -s archinstall "$0" "$@"
    else
        configure_tmux_status
    fi
}

configure_tmux_status() {
    local stats_script="/tmp/archinstall_system_stats.sh"
    generate_stats_script "$stats_script"
    chmod +x "$stats_script"

    # Start the stats script in background if needed, but tmux status-right can run it directly
    # However, tmux status-right runs often, so we want the script to be lightweight.
    
    tmux set-option -g status-interval 1
    tmux set-option -g status-position bottom
    tmux set-option -g status-style "bg=black,fg=white"
    tmux set-option -g status-left " #S "
    tmux set-option -g status-right-length 150
    tmux set-option -g status-right "#($stats_script) "
}

generate_stats_script() {
    local target="$1"
    cat << 'EOF' > "$target"
#!/bin/bash

get_cpu() {
    read cpu a b c d e f g rest < /proc/stat
    local total=$((a+b+c+d+e+f+g))
    local idle=$d
    
    if [ -f /tmp/prev_cpu ]; then
        read prev_total prev_idle < /tmp/prev_cpu
        local diff_total=$((total-prev_total))
        local diff_idle=$((idle-prev_idle))
        if [ $diff_total -eq 0 ]; then
             echo "0%"
        else
             local usage=$(( (1000 * (diff_total - diff_idle) / diff_total + 5) / 10 ))
             echo "${usage}%"
        fi
    else
        echo "..."
    fi
    echo "$total $idle" > /tmp/prev_cpu
}

get_mem() {
    read _ total _ < <(grep MemTotal /proc/meminfo)
    read _ avail _ < <(grep MemAvailable /proc/meminfo)
    
    local used=$((total - avail))
    # Convert to GB or MB
    local total_gb=$(awk "BEGIN {printf \"%.1f\", $total/1024/1024}")
    local used_gb=$(awk "BEGIN {printf \"%.1f\", $used/1024/1024}")
    
    echo "${used_gb}/${total_gb}GB"
}

get_net() {
    # Simple TX/RX summary for all interfaces (excluding lo)
    local rx_total=0
    local tx_total=0
    for iface in /sys/class/net/*; do
        base=$(basename "$iface")
        [[ "$base" == "lo" ]] && continue
        
        rx=$(cat "$iface/statistics/rx_bytes" 2>/dev/null || echo 0)
        tx=$(cat "$iface/statistics/tx_bytes" 2>/dev/null || echo 0)
        rx_total=$((rx_total + rx))
        tx_total=$((tx_total + tx))
    done

    if [ -f /tmp/prev_net ]; then
        read prev_time prev_rx prev_tx < /tmp/prev_net
        local curr_time=$(date +%s%N) # nanoseconds
        local diff_time=$(( (curr_time - prev_time) / 1000000000 ))
        [ $diff_time -eq 0 ] && diff_time=1
        
        local rx_speed=$(( (rx_total - prev_rx) / diff_time ))
        local tx_speed=$(( (tx_total - prev_tx) / diff_time ))
        
        # Format human readable
        format_speed() {
            local val=$1
            if [ $val -gt 1048576 ]; then
                awk "BEGIN {printf \"%.1f MB/s\", $val/1048576}"
            elif [ $val -gt 1024 ]; then
                awk "BEGIN {printf \"%.1f KB/s\", $val/1024}"
            else
                echo "${val} B/s"
            fi
        }
        
        echo "RX:$(format_speed $rx_speed) TX:$(format_speed $tx_speed)"
    else
        echo "Calc..."
    fi
    
    echo "$(date +%s%N) $rx_total $tx_total" > /tmp/prev_net
}

get_ip() {
    ip -4 -o addr show | awk '!/^[0-9]*: ?lo|link\/ether/ {print $4}' | cut -d/ -f1 | head -n 1
}

echo "NET: $(get_net) | CPU: $(get_cpu) | RAM: $(get_mem) | IP: $(get_ip) | $(date +'%H:%M:%S')"
EOF
}
