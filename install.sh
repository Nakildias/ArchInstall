#!/bin/bash

# --- Configuration ---
SCRIPT_VERSION="3.0" # Updated version
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
DEFAULT_REGION="America" # Default timezone region (Adjust as needed)
DEFAULT_CITY="Toronto"   # Default timezone city (Adjust as needed)
INSTALL_SUCCESS="false"
INSTALL_NVIDIA="false"

# --- Helper Functions ---

check_dependencies() {
    local dependencies=("curl" "lsblk" "sgdisk" "mkfs.ext4" "mkfs.fat" "mkswap" "wipefs" "mount" "umount" "pacstrap" "genfstab" "arch-chroot" "sed" "grep" "awk" "cryptsetup" "dmsetup")
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


show_summary() {
    info "--- Configuration Summary ---"
    echo "  Target Disk:       ${TARGET_DISK} (${TARGET_DISK_SIZE})"
    echo "  Boot Mode:         ${BOOT_MODE}"
    echo "  Partition Prefix:  ${PART_PREFIX}"
    echo "  Hostname:          ${HOSTNAME}"
    echo "  Timezone:          ${DEFAULT_REGION}/${DEFAULT_CITY}"

    if [ "$ENABLE_ROOT_ACCOUNT" == "true" ]; then
        echo "  Root Account:      Enabled"
    else
        echo "  Root Account:      Disabled (Locked)"
    fi

    echo "  User Accounts:"
    for i in "${!USER_NAMES[@]}"; do
        local u="${USER_NAMES[$i]}"
        local s="${USER_SUDO[$i]}"
        local sudo_str=""
        [[ "$s" == "true" ]] && sudo_str="(Sudo)"
        echo "    - $u $sudo_str"
    done

    echo "  Kernel:            ${SELECTED_KERNEL}"
    echo "  Desktop Env:       ${SELECTED_DE_NAME}"
    echo "  Filesystem:        ${SELECTED_FS}"

    if [ "$ENABLE_ENCRYPTION" == "true" ]; then
        echo "  Encryption:        Enabled (LUKS)"
    else
        echo "  Encryption:        Disabled"
    fi

    if [[ "$SWAP_TYPE" == "Partition" ]]; then
        echo "  Swap:              Physical Partition (${SWAP_PART_SIZE})"
    elif [[ "$SWAP_TYPE" == "ZRAM" ]]; then
        echo "  Swap:              ZRAM (Compressed RAM)"
    else
        echo "  Swap:              None"
    fi

    echo "  GPU Driver:        NVIDIA=${INSTALL_NVIDIA}"

    echo "  Base Packages:     (Standard Arch Base)"
    echo "  Optional Pkgs:     Steam=${INSTALL_STEAM}, Discord=${INSTALL_DISCORD}, Multilib=${ENABLE_MULTILIB}, UFW=${INSTALL_UFW}, Yay=${INSTALL_YAY}, Zsh=${INSTALL_ZSH}"
    echo "  Exp. Boot (kexec): ${ENABLE_KEXEC}"

    if [ "$USE_LOCAL_MIRROR" == "true" ]; then
        echo "  Mirror:            Local (${LOCAL_MIRROR_URL})"
    else
        echo "  Mirror:            Auto (Reflector)"
    fi
    echo ""
    warn "The installation will DESTROY ALL DATA on ${TARGET_DISK}."
    confirm "Do you want to proceed with these settings?" || { info "Installation cancelled by user."; exit 0; }

    # Start the timer after user confirmation
    START_TIME=$(date +%s)
}

# Secure password prompt helper
get_password() {
    local user_label="$1"
    local config_var_name="$2"
    local pass_val
    local pass_confirm

    info "Setting password for ${user_label}."
    while true; do
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Enter password for ${user_label}: ")" pass_val
        echo
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Confirm password for ${user_label}: ")" pass_confirm
        echo

        if [[ -z "$pass_val" ]]; then
            error "Password cannot be empty. Please try again."
            continue
        fi

        if [[ "$pass_val" == "$pass_confirm" ]]; then
            success "Password confirmed."
            # Return value by reference (eval) or just echo?
            # Eval is risky, but common in bash.
            # Better: export the variable or use printf -v (bash 3.1+)
            printf -v "$config_var_name" "%s" "$pass_val"
            break
        else
            error "Passwords do not match. Please try again."
        fi
    done
}

# Color definitions
C_OFF='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'
C_BOLD='\033[1m'

# Logging functions
log_to_file() {
    echo -e "$1" | sed 's/\x1b\[[0-9;]*m//g' >> "$LOG_FILE"
}

info() {
    local msg="${C_BLUE}${C_BOLD}[INFO]${C_OFF} $1"
    echo -e "$msg"
    log_to_file "[INFO] $1"
}
warn() {
    local msg="${C_YELLOW}${C_BOLD}[WARN]${C_OFF} $1"
    echo -e "$msg"
    log_to_file "[WARN] $1"
}
error() {
    local msg="${C_RED}${C_BOLD}[ERROR]${C_OFF} $1"
    echo -e "$msg"
    log_to_file "[ERROR] $1"
}
success() {
    local msg="${C_GREEN}${C_BOLD}[SUCCESS]${C_OFF} $1"
    echo -e "$msg"
    log_to_file "[SUCCESS] $1"
}

# Standard prompt - reads into the variable name passed as $2
prompt() {
    read -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} $1")" "$2"
}

# Confirmation prompt
confirm() {
    while true; do
        # Use direct read for confirmation prompt
        read -p "$(echo -e "${C_YELLOW}${C_BOLD}[CONFIRM]${C_OFF} ${1} [y/N]: ")" yn
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no|"") return 1 ;;
            *) error "Please answer yes or no." ;;
        esac
    done
}

# Check command exit status
check_status() {
    local status=$? # Capture status immediately
    if [ $status -ne 0 ]; then
        error "Command failed with status $status: $1"
        # Optional: Add cleanup logic here if needed before exit
        exit 1
    fi
    # Return the original status if needed elsewhere
    return $status
}

# Exit handler for cleanup
trap 'cleanup' EXIT SIGHUP SIGINT SIGTERM
cleanup() {
    # If explicitly successful, skip error messages
    if [[ "$INSTALL_SUCCESS" == "true" ]]; then
        tput cnorm
        return
    fi

    # Check if SWAP_PARTITION was assigned before trying to use it in error message
    local swap_info=""
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
       swap_info=" and swap ${SWAP_PARTITION}"
    fi

    error "--- SCRIPT INTERRUPTED OR FAILED ---"
    info "Performing cleanup... Attempting to unmount /mnt/boot, /mnt${swap_info}"

    # Attempt to unmount everything in reverse order in case of script failure
    # Use &>/dev/null to suppress errors if already unmounted
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    # Deactivate swap if it was activated and variable exists
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
       swapoff "${SWAP_PARTITION}" &>/dev/null
    fi
    info "Cleanup finished. If the script failed, some resources might still be mounted/active."
    info "Check with 'lsblk' and 'mount'."
    # Ensure cursor is visible and colors are reset on exit
    tput cnorm
    echo -e "${C_OFF}"
    INSTALL_SUCCESS="true"
}

# --- Main Installation Logic ---

main() {
    # Initial setup
    setup_environment

    # --- MODIFICATION START: Load Multi-Profile Config ---
    USE_CONFIG="false"
    CONFIG_DIR="./config"

    # Check if config directory exists and has .conf files
    if [ -d "$CONFIG_DIR" ] && compgen -G "${CONFIG_DIR}/*.conf" > /dev/null; then
        echo -e "${C_CYAN}Found configuration profiles in ${CONFIG_DIR}:${C_OFF}"

        # Create an array of config files
        mapfile -t config_files < <(ls "${CONFIG_DIR}"/*.conf)

        # Add an option for "None (Interactive Mode)"
        options=("${config_files[@]}" "None (Interactive Mode)")

        PS3="Select a profile to load (Enter ID): "
        select config_choice in "${options[@]}"; do
            if [[ "$config_choice" == "None (Interactive Mode)" ]]; then
                 info "Proceeding with interactive mode (No config loaded)."
                 break
            elif [[ -n "$config_choice" ]]; then
                 CONFIG_FILE="$config_choice"
                 info "Loading configuration from: ${CONFIG_FILE}"
                 source "$CONFIG_FILE"
                 USE_CONFIG="true"
                 break
            else
                 echo "Invalid selection. Please try again."
            fi
        done
    else
        echo "No configuration profiles found in ${CONFIG_DIR}. Proceeding interactively."
    fi
    # --- MODIFICATION END ---

    check_dependencies

    # Pre-installation checks
    check_boot_mode
    check_internet

    # User configuration gathering
    select_disk             # KEEPS INTERACTIVE (As requested)
    configure_partitioning  # MODIFIED (Uses config if present)
    configure_hostname_user # MODIFIED (Hostname from config, Users interactive)
    select_timezone         # MODIFIED
    select_kernel           # MODIFIED
    select_bootloader       # MODIFIED
    select_gpu_driver       # MODIFIED
    select_desktop_environment # MODIFIED
    select_filesystem       # MODIFIED
    select_swap_choice      # MODIFIED
    ask_encryption          # MODIFIED (Choice from config, Password interactive)
    select_optional_packages # MODIFIED
    ask_kexec_preference    # MODIFIED
    select_mirror_preference # MODIFIED
    show_summary

    # Perform installation steps
    configure_mirrors             # Enables multilib based on INSTALL_STEAM or ENABLE_MULTILIB
    partition_and_format          # Creates partitions: p1=root, p2=boot, p3=swap, [p4=BIOS Boot]
    mount_filesystems             # Mounts p1 and p2, activates p3
    install_base_system           # Installs packages including Steam if selected
    configure_installed_system    # Configures chroot, ensures multilib based on INSTALL_STEAM or ENABLE_MULTILIB
    install_bootloader            # Installs GRUB (should now work for BIOS/GPT)

    # Finalization
    final_steps
}

# --- Function Definitions ---

cleanup_disk_state() {
    local disk="$1"
    info "Performing aggressive disk cleanup on ${disk}..."

    # 1. Turn off all swap (to release any swap partitions on this disk)
    swapoff -a &>/dev/null || true

    # 2. Force close any cryptsetup containers (e.g. leftovers from failed installs)
    # We attempt common names.
    cryptsetup close cryptroot &>/dev/null || true

    # 3. Aggressive dmsetup remove to clear device mapper targets
    # This clears stuck mappings that prevent wiping
    dmsetup remove_all --force &>/dev/null || true

    # 4. Wipefs again just to be sure
    wipefs --all --force "${disk}" &>/dev/null || true

    success "Disk cleanup complete."
}

setup_environment() {
    # Ensure script is run as root
    if [ "$EUID" -ne 0 ]; then
        echo "Please run as root."
        exit 1
    fi

    # Exit immediately if a command exits with a non-zero status.
    set -e
    # Cause pipelines to return the exit status of the last command that failed.
    set -o pipefail
    # Treat unset variables as an error when substituting.
    set -u

    # Setup Logging
    LOG_FILE="/var/log/archinstall.log"
    # Note: Global redirection (exec > >(tee ...)) is disabled to preserve
    # Pacman's progress bars which require a TTY.
    # We will log manually in the helper functions.

    info "Starting Arch Linux Installation Script v${SCRIPT_VERSION}"
    info "Log file: ${LOG_FILE}"
    info "Current Time: $(date)"
    # Ensure cursor is visible if script exits unexpectedly
    tput cnorm
}

check_boot_mode() {
    info "Checking boot mode..."
    if [ -d "/sys/firmware/efi/efivars" ]; then
        BOOT_MODE="UEFI"
        success "System booted in UEFI mode."
    else
        BOOT_MODE="BIOS"
        success "System booted in Legacy BIOS mode."
        warn "Legacy BIOS mode detected. Installation will use GPT with BIOS boot settings (requires BIOS Boot Partition)."
    fi
    # Confirmation removed, proceeding automatically.
    info "Proceeding with ${BOOT_MODE} installation automatically."
}

check_internet() {
    info "Checking internet connectivity..."
    ARCH_WEBSITE_REACHABLE="true"

    if timeout 3 ping -c 1 archlinux.org &> /dev/null; then
        success "Connection to archlinux.org verified."
    else
        warn "Could not reach archlinux.org."
        info "Checking fallback connectivity (google.ca)..."
        if timeout 3 ping -c 1 google.ca &> /dev/null; then
            ARCH_WEBSITE_REACHABLE="false"
            warn "Internet is reachable, but archlinux.org is down."
            warn "Some features (like automatic mirror selection with reflector) may require archlinux.org."
            if ! confirm "Do you want to proceed anyway? (Reflector will be skipped)"; then
                info "Installation aborted by user."
                exit 1
            fi
        else
            error "No internet connection detected (checked archlinux.org and google.ca)."
            exit 1
        fi
    fi
}

select_disk() {
    info "Detecting available block devices..."
    # Use lsblk to get NAME, TYPE, SIZE, and ensure it's a disk (exclude rom, loop)
    mapfile -t devices < <(lsblk -dnpo name,type,size | awk '$2=="disk"{print $1" ("$3")"}')

    if [ ${#devices[@]} -eq 0 ]; then
        error "No disks found. Ensure drives are properly connected."
        exit 1
    fi

    echo "Available disks:"
    select device_choice in "${devices[@]}"; do
        if [[ -n "$device_choice" ]]; then
            # Extract just the name (e.g., /dev/sda)
            TARGET_DISK=$(echo "$device_choice" | awk '{print $1}')
            TARGET_DISK_SIZE=$(echo "$device_choice" | awk '{print $2}')
            info "Selected disk: ${C_BOLD}${TARGET_DISK}${C_OFF} (${TARGET_DISK_SIZE})"
            break
        else
            error "Invalid selection. Please try again."
        fi
    done

    warn "ALL DATA ON ${C_BOLD}${TARGET_DISK}${C_OFF} WILL BE ERASED!"
    confirm "Are you absolutely sure you want to partition ${TARGET_DISK}?" || { info "Operation cancelled by user."; exit 0; }

    # Wiping is done thoroughly in partition_and_format before sgdisk runs
    info "Disk ${TARGET_DISK} selected. Wiping will occur before partitioning."
    sleep 1
}

select_swap_choice() {
    info "Swap Configuration..."

    if [[ "$USE_CONFIG" == "true" && -n "$SWAP_TYPE" ]]; then
        info "Using Swap Type from config: $SWAP_TYPE"

        # If partition, check size too
        if [[ "$SWAP_TYPE" == "Partition" && -n "$SWAP_PART_SIZE" ]]; then
             info "Using Swap Partition Size from config: $SWAP_PART_SIZE"
        fi
        return
    fi

    # Define options with Pros/Cons
    swap_options=(
        "ZRAM      | RAM Compression | Pros: Fastest performance, saves SSD life | Cons: No Hibernation"
        "Partition | Physical Disk   | Pros: Supports Hibernation              | Cons: Slower, reserves disk space"
        "None      | No Swap         | Pros: Max disk space                    | Cons: System freeze if RAM fills up"
    )

    echo "Select Swap Type:"
    (
        COLUMNS=1
        select swap_opt in "${swap_options[@]}"; do
            if [[ -n "$swap_opt" ]]; then
                local selection=$(echo "$swap_opt" | awk '{print $1}')
                echo "$selection" > /tmp/arch_swap_choice
                break
            else
                error "Invalid selection."
            fi
        done
    )

    if [ -f /tmp/arch_swap_choice ]; then
        SWAP_TYPE=$(cat /tmp/arch_swap_choice)
        rm /tmp/arch_swap_choice
    else
        SWAP_TYPE="ZRAM" # Default fallback
    fi

    info "Selected Swap Type: ${C_BOLD}${SWAP_TYPE}${C_OFF}"

    # Handle configuration based on choice
    SWAP_PART_SIZE="" # Reset default

    if [[ "$SWAP_TYPE" == "Partition" ]]; then
        while true; do
            prompt "Enter Swap Partition size (e.g., 4G, 8G): " SWAP_INPUT
            if [[ "$SWAP_INPUT" =~ ^[0-9]+[MG]$ ]]; then
                SWAP_PART_SIZE=$SWAP_INPUT
                info "Swap partition size set to: ${SWAP_PART_SIZE}"
                break
            else
                error "Invalid format. Use number followed by M or G (e.g., 4G, 8G)."
            fi
        done
    elif [[ "$SWAP_TYPE" == "ZRAM" ]]; then
        info "ZRAM will be configured automatically (Size: min(RAM, 8GB), Algo: zstd)."
    else
        info "No swap will be configured."
    fi
}

select_filesystem() {
    info "Selecting Filesystem..."

    if [[ "$USE_CONFIG" == "true" && -n "$SELECTED_FS" ]]; then
        info "Using Filesystem from config: $SELECTED_FS"
        return
    fi

    # Define options with Pros/Cons
    filesystems=(
        "ext4  | The Standard | Pros: Rock solid, very stable | Cons: No snapshots"
        "btrfs | Modern Feature-Rich | Pros: Snapshots, compression | Cons: Slightly slower, complex"
        "xfs   | High Performance | Pros: Fast for large files, parallel I/O | Cons: Cannot shrink partition"
    )

    echo "Select a filesystem for the Root partition (Encryption supported on all):"

    # Run menu in subshell to force vertical list (COLUMNS=1) without messing up global layout
    (
        COLUMNS=1
        select fs_choice in "${filesystems[@]}"; do
            if [[ -n "$fs_choice" ]]; then
                # Extract the first word (ext4, btrfs, xfs)
                local selection=$(echo "$fs_choice" | awk '{print $1}')

                # Write to temp file to pass variable out of subshell
                echo "$selection" > /tmp/arch_fs_choice
                break
            else
                error "Invalid selection."
            fi
        done
    )

    # Read the choice back from the temp file
    if [ -f /tmp/arch_fs_choice ]; then
        SELECTED_FS=$(cat /tmp/arch_fs_choice)
        rm /tmp/arch_fs_choice
        info "Selected Filesystem: ${C_BOLD}${SELECTED_FS}${C_OFF}"
    else
        # Fallback safety
        SELECTED_FS="ext4"
        warn "Selection failed. Defaulting to ext4."
    fi
}

ask_encryption() {
    info "Disk Encryption Setup"

    # MODIFIED: Check config for enablement choice
    if [[ "$USE_CONFIG" == "true" ]]; then
        if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
             info "Encryption enabled via config."
             get_password "Disk Encryption (LUKS)" "LUKS_PASSWORD"
             return
        else
             info "Encryption disabled via config."
             LUKS_PASSWORD=""
             return
        fi
    fi

    ENABLE_ENCRYPTION="false"
    LUKS_PASSWORD=""

    echo "Encryption protects your data if your device is stolen."
    echo "Note: You will need to type a password every time you boot."

    if confirm "Encrypt the installation (LUKS)?"; then
        ENABLE_ENCRYPTION="true"
        get_password "Disk Encryption (LUKS)" "LUKS_PASSWORD"
        info "Encryption enabled. The root partition will be encrypted."
    else
        info "Encryption skipped. Standard plain partitions will be used."
    fi
}

configure_partitioning() {
    info "Configuring partition layout sizes."

    # MODIFIED: Check config for boot size
    if [[ "$USE_CONFIG" == "true" && -n "$BOOT_PART_SIZE" ]]; then
         BOOT_PART_SIZE=$BOOT_PART_SIZE
         info "Using Boot Partition size from config: ${BOOT_PART_SIZE}"
    else
        # Boot Partition Size
        while true; do
            prompt "Enter Boot Partition size (e.g., 550M, 1G) [${MIN_BOOT_SIZE_MB}M minimum, recommended 550M+]: " BOOT_SIZE_INPUT
            BOOT_SIZE_INPUT=${BOOT_SIZE_INPUT:-550M} # Default if empty
            if [[ "$BOOT_SIZE_INPUT" =~ ^[0-9]+[MG]$ ]]; then
                local size_num=$(echo "$BOOT_SIZE_INPUT" | sed 's/[MG]$//')
                local size_unit=$(echo "$BOOT_SIZE_INPUT" | grep -o '[MG]$')
                local size_mb=$size_num
                [[ "$size_unit" == "G" ]] && size_mb=$((size_num * 1024))

                if (( size_mb >= MIN_BOOT_SIZE_MB )); then
                    BOOT_PART_SIZE=$BOOT_SIZE_INPUT
                    info "Boot partition size set to: ${BOOT_PART_SIZE}"
                    break
                else
                    error "Boot size must be at least ${MIN_BOOT_SIZE_MB}M."
                fi
            else
                error "Invalid format. Use number followed by M or G (e.g., 550M, 1G)."
            fi
        done
    fi

    # Determine Partition Naming Convention (e.g., /dev/sda1 vs /dev/nvme0n1p1)
    # TARGET_DISK already includes /dev/ prefix (e.g., /dev/sda, /dev/nvme0n1)
    if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
        # For NVMe/eMMC disks, partitions are like /dev/nvme0n1p1, /dev/mmcblk0p1
        PART_PREFIX="${TARGET_DISK}p"
    else
        # For SATA/SCSI/IDE disks, partitions are like /dev/sda1, /dev/sdb2
        PART_PREFIX="${TARGET_DISK}"
    fi
    # PART_PREFIX will correctly form partition names when the number is appended.
    info "Partition name prefix determined: ${PART_PREFIX}"
}

configure_hostname_user() {
    info "Configuring system identity..."

    # MODIFIED: Skip hostname prompt if configured
    if [[ "$USE_CONFIG" == "true" && -n "$HOSTNAME" ]]; then
        info "Using hostname from config: ${HOSTNAME}"
    else
        while true; do
            prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
            # Strict validation: alphanumeric and hyphens only, lowercase recommended
            if [[ "$HOSTNAME" =~ ^[a-z0-9-]+$ ]]; then
                break
            else
                error "Hostname invalid. Use lowercase letters, numbers, and hyphens only."
            fi
        done
    fi

    # --- Root Account Configuration ---
    ENABLE_ROOT_ACCOUNT=false
    ROOT_PASSWORD=""
    if confirm "Enable Root account? (If no, root will be locked and sudo recommended)"; then
        ENABLE_ROOT_ACCOUNT=true
        get_password "root user" "ROOT_PASSWORD"
    else
        info "Root account will be disabled (locked)."
    fi

    # --- User Accounts Configuration ---
    USER_NAMES=()
    USER_PASSWORDS=()
    USER_SUDO=()

    info "Configuring user accounts..."
    while true; do
        # If no users yet, we must force adding at least one
        if [ ${#USER_NAMES[@]} -eq 0 ]; then
             info "You must create at least one user account."
        elif ! confirm "Add another user?"; then
             break
        fi

        while true; do
            prompt "Enter username: " CURRENT_USER
            # Strict validation
            if [[ "$CURRENT_USER" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
                # Check for duplicates
                local is_dup=false
                for existing in "${USER_NAMES[@]}"; do
                    if [[ "$existing" == "$CURRENT_USER" ]]; then
                        is_dup=true
                        break
                    fi
                done

                if [[ "$is_dup" == "true" ]]; then
                    error "Username '$CURRENT_USER' already added."
                    continue
                fi

                info "Username set to: ${CURRENT_USER}"
                break
            else
                error "Username invalid. Must start with letter/underscore, contain lowercase alphanumeric/-/_ only."
            fi
        done

        get_password "user '${CURRENT_USER}'" "CURRENT_PASS"

        local use_sudo="false"
        if confirm "Grant sudo rights (wheel group) to '${CURRENT_USER}'?"; then
            use_sudo="true"
        fi

        # Add to arrays
        USER_NAMES+=("$CURRENT_USER")
        USER_PASSWORDS+=("$CURRENT_PASS")
        USER_SUDO+=("$use_sudo")

        success "User '${CURRENT_USER}' added to configuration."
    done
}

select_kernel() {
    info "Selecting Kernel..."

    if [[ "$USE_CONFIG" == "true" && -n "$SELECTED_KERNEL" ]]; then
        info "Using Kernel from config: $SELECTED_KERNEL"
        return
    fi

    kernels=("linux" "linux-lts" "linux-zen")
    echo "Available kernels:"
    select kernel_choice in "${kernels[@]}"; do
        if [[ -n "$kernel_choice" ]]; then
            SELECTED_KERNEL=$kernel_choice
            info "Selected kernel: ${C_BOLD}${SELECTED_KERNEL}${C_OFF}"
            break
        else
            error "Invalid selection."
        fi
    done
}

select_bootloader() {
    # 1. If BIOS mode, we cannot use systemd-boot. Force GRUB.
    if [[ "$BOOT_MODE" == "BIOS" ]]; then
        SELECTED_BOOTLOADER="grub"
        # info "Legacy BIOS detected. Forcing GRUB bootloader (systemd-boot is UEFI only)."
        return
    fi

    info "Selecting Bootloader..."

    if [[ "$USE_CONFIG" == "true" && -n "$SELECTED_BOOTLOADER" ]]; then
        info "Using Bootloader from config: $SELECTED_BOOTLOADER"
        return
    fi

    # 2. Define options with descriptions as requested
    bootloaders=(
        "GRUB         | Heavy & Robust | Pros: Highly compatible, themable | Cons: Slower, complex config"
        "systemd-boot | Light & Fast   | Pros: Very fast, simple text config | Cons: UEFI only, simple UI"
    )

    echo "Select a bootloader:"

    # Force vertical list
    (
        COLUMNS=1
        select bl_choice in "${bootloaders[@]}"; do
            if [[ -n "$bl_choice" ]]; then
                # Extract the first word (GRUB or systemd-boot)
                CHOICE_NAME=$(echo "$bl_choice" | awk '{print $1}')

                # Write choice to a temp file to pass it out of the subshell
                if [[ "$CHOICE_NAME" == "GRUB" ]]; then
                    echo "grub" > /tmp/arch_install_bl_choice
                else
                    echo "systemd-boot" > /tmp/arch_install_bl_choice
                fi
                break
            else
                error "Invalid selection."
            fi
        done
    )

    # 3. Retrieve the value from the temp file
    if [ -f /tmp/arch_install_bl_choice ]; then
        SELECTED_BOOTLOADER=$(cat /tmp/arch_install_bl_choice)
        rm /tmp/arch_install_bl_choice
        info "Selected bootloader: ${C_BOLD}${SELECTED_BOOTLOADER}${C_OFF}"
    else
        # Safety fallback if something went wrong
        SELECTED_BOOTLOADER="grub"
        warn "Selection failed. Defaulting to GRUB."
    fi
}

select_desktop_environment() {
    info "Selecting Desktop Environment or Server..."

    # Initialize to empty string to prevent unbound variable error (set -u)
    AUTO_LOGIN_USER=""

    # MODIFIED: Map string from config to index
    if [[ "$USE_CONFIG" == "true" && -n "$SELECTED_DE_NAME" ]]; then
        case "${SELECTED_DE_NAME,,}" in # Convert to lowercase for matching
            server*) SELECTED_DE_INDEX=0 ;;
            kde*)    SELECTED_DE_INDEX=1 ;;
            gnome*)  SELECTED_DE_INDEX=2 ;;
            xfce*)   SELECTED_DE_INDEX=3 ;;
            lxqt*)   SELECTED_DE_INDEX=4 ;;
            mate*)   SELECTED_DE_INDEX=5 ;;
            nakildias*) SELECTED_DE_INDEX=6 ;;
            *)       SELECTED_DE_INDEX="" ;; # Invalid, force prompt
        esac

        if [[ -n "$SELECTED_DE_INDEX" ]]; then
            info "Using Desktop Environment from config: ${SELECTED_DE_NAME} (Index: ${SELECTED_DE_INDEX})"

            # Handle Auto-Login from Config
            if [[ "$ENABLE_AUTO_LOGIN" == "true" && "$SELECTED_DE_INDEX" -ne 0 ]]; then
                # We can't set AUTO_LOGIN_USER here because users might not be created yet
                # (User creation loop is interactive).
                # Logic: If config says auto-login, we assume the FIRST user created.
                if [ ${#USER_NAMES[@]} -gt 0 ]; then
                    AUTO_LOGIN_USER="${USER_NAMES[0]}"
                    info "Auto-login configured for first user: ${AUTO_LOGIN_USER}"
                fi
            fi
            return
        fi
    fi

    desktops=(
        "Server (No GUI) | Ultra-Light | Pros: Max speed, secure | Cons: No interface"
        "KDE Plasma (Modern) | Heavy | Pros: Ultimate customization | Cons: Complex settings"
        "GNOME (Modern) | Heavy | Pros: Polished, simple workflow | Cons: High RAM usage"
        "XFCE (Classic) | Lightweight | Pros: Rock solid, fast | Cons: Dated out-of-box"
        "LXQt (Minimal) | Lightweight | Pros: Fastest GUI, modular | Cons: Basic features"
        "MATE (Traditional) | Mid-Weight | Pros: Classic feel, stable | Cons: Lacks modern flair"
        "KDE Plasma (Nakildias) | Heavy+ | Pros: Fully featured, pre-tuned | Cons: Heaviest option"
    )

    echo "Available environments:"

    # Force vertical alignment by setting COLUMNS to 1
    (
        COLUMNS=1
        select de_choice in "${desktops[@]}"; do
            if [[ -n "$de_choice" ]]; then
                # Export the choice so it leaves the subshell
                echo "$de_choice" > /tmp/de_choice
                echo "$REPLY" > /tmp/de_reply
                break
            else
                error "Invalid selection."
            fi
        done
    )

    # Retrieve values from the subshell
    SELECTED_DE_NAME=$(cat /tmp/de_choice)
    SELECTED_DE_INDEX=$(($(cat /tmp/de_reply) - 1))
    rm /tmp/de_choice /tmp/de_reply

    info "Selected environment: ${C_BOLD}${SELECTED_DE_NAME}${C_OFF}"

    # --- Auto-Login Logic ---
    AUTO_LOGIN_USER=""
    # Index 0 is Server, so we skip auto-login for it
    if [[ "$SELECTED_DE_INDEX" -ne 0 ]]; then
        if confirm "Enable Auto-Login? (Logs in automatically without password)"; then
            # If there is only one user, pick it automatically
            if [ ${#USER_NAMES[@]} -eq 1 ]; then
                AUTO_LOGIN_USER="${USER_NAMES[0]}"
                info "Auto-login enabled for user: ${AUTO_LOGIN_USER}"
            else
                # If multiple users, let them pick
                echo "Select user for auto-login:"
                select u in "${USER_NAMES[@]}"; do
                    if [[ -n "$u" ]]; then
                        AUTO_LOGIN_USER="$u"
                        break
                    else
                        error "Invalid selection."
                    fi
                done
            fi
        fi
    fi

}

select_gpu_driver() {
    info "GPU Driver Selection..."

    # MODIFIED: Automatic Detection ONLY (User requested automation override)
    # We ignore config values for this specific function to ensure hardware match.

    if lspci | grep -i "NVIDIA" >/dev/null; then
        warn "NVIDIA GPU detected. Enabling proprietary drivers automatically."
        INSTALL_NVIDIA="true"
    else
        info "No NVIDIA GPU detected (or using AMD/Intel). Standard drivers will be used."
        INSTALL_NVIDIA="false"
    fi
}

select_optional_packages() {
    info "Optional Packages Selection..."

    if [[ "$USE_CONFIG" == "true" ]]; then
        # Map Steam/Discord logic
        INSTALL_DISCORD="$INSTALL_STEAM"
        ENABLE_MULTILIB="$INSTALL_STEAM"

        info "Using Optional Packages from config:"
        echo " - Steam/Discord: $INSTALL_STEAM"
        echo " - UFW: $INSTALL_UFW"
        echo " - Yay: $INSTALL_YAY"
        echo " - Zsh: $INSTALL_ZSH"
        return
    fi

    INSTALL_STEAM=false
    INSTALL_DISCORD=false
    ENABLE_MULTILIB=false

    # Check for Gaming Essentials (Steam + Discord + Multilib)
    if confirm "Install Gaming Essentials? (Steam, Discord, and Multilib support)"; then
        INSTALL_STEAM=true
        INSTALL_DISCORD=true
        ENABLE_MULTILIB=true
        info "Gaming Essentials will be installed (Steam, Discord, Multilib)."
    else
        info "Gaming Essentials will not be installed."
    fi

    # Check for Firewall (UFW)
    INSTALL_UFW=false
    if confirm "Install and Enable Firewall (UFW)?"; then
        INSTALL_UFW=true
        info "UFW will be installed and enabled."
    else
        info "UFW will NOT be installed."
    fi

    # Check for Yay (AUR Helper)
    INSTALL_YAY=false
    if confirm "Install Yay (AUR Helper)?"; then
        INSTALL_YAY=true
        info "Yay will be installed for all users."
    else
        info "Yay will NOT be installed."
    fi

    # Check for Zsh
    INSTALL_ZSH=false
    if confirm "Install Zsh Shell? (Required for post-install customization)"; then
        INSTALL_ZSH=true
        info "Zsh will be installed."
    else
        info "Zsh will NOT be installed."
    fi
}

ask_kexec_preference() {
    info "Experimental Boot Option"

    if [[ "$USE_CONFIG" == "true" && -n "$ENABLE_KEXEC" ]]; then
         info "Using Kexec setting from config: $ENABLE_KEXEC"
         return
    fi
    ENABLE_KEXEC="false"

    echo "This script supports 'kexec', which allows you to boot directly into your new"
    echo "Arch installation immediately after finishing, skipping the BIOS/POST hardware restart."
    echo "NOTE: This is experimental. If it fails, you just need to reboot manually."

    if confirm "Enable 'Boot without Restart' (kexec) at the end of installation?"; then
        ENABLE_KEXEC="true"
        info "Kexec boot enabled. System will attempt to hot-swap kernels at the end."
    else
        info "Standard reboot selected."
    fi
}

select_mirror_preference() {
    info "Mirror Configuration..."

    if [[ "$USE_CONFIG" == "true" ]]; then
        if [[ "$USE_LOCAL_MIRROR" == "true" && -n "$LOCAL_MIRROR_URL" ]]; then
             info "Using Local Mirror from config: $LOCAL_MIRROR_URL"
             return
        fi
    fi

    USE_LOCAL_MIRROR="false"
    LOCAL_MIRROR_URL=""
    if confirm "Use local mirror? (e.g. for caching servers)"; then
        while true; do
            prompt "Enter local mirror URL (e.g. http://192.168.1.104:8000/): " LOCAL_MIRROR_URL
            if [[ -n "$LOCAL_MIRROR_URL" ]]; then
                # Remove trailing slash if present
                LOCAL_MIRROR_URL="${LOCAL_MIRROR_URL%/}"
                USE_LOCAL_MIRROR="true"
                info "Local mirror selected: ${LOCAL_MIRROR_URL}"
                break
            else
                error "URL cannot be empty."
            fi
        done
    else
        info "Using automatic mirror selection (Reflector)."
    fi
}

configure_mirrors() {
    info "Configuring Pacman mirrors for optimal download speed..."
    warn "This may take a few moments."

    # Backup original mirrorlist
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    check_status "Backing up mirrorlist"


    # Getting current country based on IP for reflector (requires curl)
    if [[ "$USE_LOCAL_MIRROR" == "true" ]]; then
        info "Applying pre-selected local mirror configuration..."
        # Write the server line to mirrorlist
        echo "Server = ${LOCAL_MIRROR_URL}/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
        success "Local mirror configured: ${LOCAL_MIRROR_URL}/archlinux/\$repo/os/\$arch"
    elif [ "$ARCH_WEBSITE_REACHABLE" = "true" ]; then
        info "Attempting to detect country for mirror selection..."
        # Use -fsSL: fail silently, follow redirects, show errors
        # Use --connect-timeout to prevent long waits
        CURRENT_COUNTRY_CODE=$(curl -fsSL --connect-timeout 5 https://ipinfo.io/country)

        if [[ -n "$CURRENT_COUNTRY_CODE" ]] && [[ ${#CURRENT_COUNTRY_CODE} -eq 2 ]]; then
            info "Detected country code: ${CURRENT_COUNTRY_CODE}. Using it for reflector."
            REFLECTOR_COUNTRIES="--country ${CURRENT_COUNTRY_CODE}"
        else
            warn "Could not detect country code automatically. Using default country (Canada)."
            # Fallback country (update if needed)
            REFLECTOR_COUNTRIES="--country Canada"
        fi

        # Run reflector: latest 20, HTTPS only, sort by download rate, save to mirrorlist
        # Add --verbose for more output during the process
        reflector --verbose ${REFLECTOR_COUNTRIES} --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
        check_status "Running reflector"

        success "Mirrorlist updated."
    else
        warn "Skipping Reflector (archlinux.org unreachable). Using default mirrorlist."
    fi

    success "Mirrorlist configured."

    # Automatically enable parallel downloads and color in pacman.conf
    PARALLEL_DL_COUNT=5
    info "Automatically enabling color and setting parallel downloads to ${PARALLEL_DL_COUNT}."

    # Use robust sed commands to uncomment or add lines if missing
    sed -i -E \
        -e 's/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = '"$PARALLEL_DL_COUNT"'/' \
        -e 's/^[[:space:]]*(ParallelDownloads).*/\1 = '"$PARALLEL_DL_COUNT"'/' \
        /etc/pacman.conf
    if ! grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
        echo "ParallelDownloads = ${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
    fi

    sed -i -E \
        -e 's/^[[:space:]]*#[[:space:]]*(Color)/\1/' \
        /etc/pacman.conf
    if ! grep -q -E "^[[:space:]]*Color" /etc/pacman.conf; then
        echo "Color" >> /etc/pacman.conf
    fi

    sed -i -E \
        -e 's/^[[:space:]]*#[[:space:]]*(VerbosePkgLists)/\1/' \
        /etc/pacman.conf
    if ! grep -q -E "^[[:space:]]*VerbosePkgLists" /etc/pacman.conf; then
        echo "VerbosePkgLists" >> /etc/pacman.conf
    fi

    # === Enable Multilib repository IF Steam OR Enable Multilib was selected ===
    if [ "$INSTALL_STEAM" = "true" ] || [ "$ENABLE_MULTILIB" = "true" ]; then
        info "Enabling Multilib repository..."
        sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
        check_status "Enabling multilib repository in /etc/pacman.conf"
        success "Multilib repository enabled."
    else
        info "Multilib repository will remain disabled (Neither Steam nor the explicit option was selected)."
    fi

    # Refresh package databases with new mirrors and settings
    info "Synchronizing package databases..."
    pacman -Syy
    check_status "pacman -Syy"
    # Update keyring so user doesn't get corrupted package errors
    echo "Updating archlinux-keyring..."
    pacman -Sy archlinux-keyring --noconfirm
    check_status "Updating archlinux-keyring"
}

partition_and_format() {
    # Define partitions
    local ROOT_PART_NUM=1
    local BOOT_PART_NUM=2
    local SWAP_PART_NUM=3
    local BIOS_BOOT_PART_NUM=4

    # Initialize SWAP_PARTITION to empty string to prevent "unbound variable" error
    SWAP_PARTITION=""
    # Only assign a partition path if user specifically chose "Partition"
    if [[ "$SWAP_TYPE" == "Partition" && -n "$SWAP_PART_SIZE" ]]; then
        SWAP_PARTITION="${PART_PREFIX}${SWAP_PART_NUM}"
    fi

    ROOT_PARTITION="${PART_PREFIX}${ROOT_PART_NUM}"
    BOOT_PARTITION="${PART_PREFIX}${BOOT_PART_NUM}"

    # Only set SWAP_PARTITION if a size was provided
    if [[ -n "$SWAP_PART_SIZE" ]]; then
        SWAP_PARTITION="${PART_PREFIX}${SWAP_PART_NUM}"
    fi

    local BIOS_BOOT_PARTITION="${PART_PREFIX}${BIOS_BOOT_PART_NUM}"

    # --- Wiping and Partitioning ---
    info "Wiping and partitioning ${TARGET_DISK}..."

    # AGGRESSIVE CLEANUP for re-installations
    cleanup_disk_state "${TARGET_DISK}"

    wipefs --all --force "${TARGET_DISK}" >/dev/null 2>&1 || true
    sgdisk --zap-all "${TARGET_DISK}"

    # Create partitions (Standard layout)
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        sgdisk -n ${BOOT_PART_NUM}:0:+${BOOT_PART_SIZE} -t ${BOOT_PART_NUM}:EF00 -c ${BOOT_PART_NUM}:"EFISystem" "${TARGET_DISK}"
    else
        sgdisk -n ${BOOT_PART_NUM}:0:+${BOOT_PART_SIZE} -t ${BOOT_PART_NUM}:8300 -c ${BOOT_PART_NUM}:"BIOSBoot" "${TARGET_DISK}"
        sgdisk -n ${BIOS_BOOT_PART_NUM}:0:+1MiB -t ${BIOS_BOOT_PART_NUM}:EF02 -c ${BIOS_BOOT_PART_NUM}:"BIOSBootPartition" "${TARGET_DISK}"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        sgdisk -n ${SWAP_PART_NUM}:0:+${SWAP_PART_SIZE} -t ${SWAP_PART_NUM}:8200 -c ${SWAP_PART_NUM}:"LinuxSwap" "${TARGET_DISK}"
    fi

    # Root gets remaining space
    sgdisk -n ${ROOT_PART_NUM}:0:0 -t ${ROOT_PART_NUM}:8300 -c ${ROOT_PART_NUM}:"LinuxRoot" "${TARGET_DISK}"

    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 3

    # --- ENCRYPTION LOGIC ---
    TARGET_ROOT_DEVICE="${ROOT_PARTITION}" # Default to raw partition
    MAPPER_NAME="cryptroot"

    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        info "Encrypting Root Partition ${ROOT_PARTITION}..."

        # Format partition with LUKS (passing password via stdin)
        echo -n "${LUKS_PASSWORD}" | cryptsetup -q luksFormat "${ROOT_PARTITION}" -
        check_status "LUKS Format"

        # Open the encrypted container
        echo -n "${LUKS_PASSWORD}" | cryptsetup open "${ROOT_PARTITION}" "${MAPPER_NAME}" -
        check_status "Opening LUKS container"

        # Point the formatter to the MAPPER device, not the raw partition
        TARGET_ROOT_DEVICE="/dev/mapper/${MAPPER_NAME}"
        success "Encrypted container opened at ${TARGET_ROOT_DEVICE}"
    fi

    # --- FORMATTING (Dynamic Filesystem) ---
    info "Formatting Root (${TARGET_ROOT_DEVICE}) as ${SELECTED_FS}..."

    case "$SELECTED_FS" in
        ext4)
            mkfs.ext4 -F "${TARGET_ROOT_DEVICE}"
            ;;
        btrfs)
            mkfs.btrfs -f "${TARGET_ROOT_DEVICE}"
            ;;
        xfs)
            mkfs.xfs -f "${TARGET_ROOT_DEVICE}"
            ;;
    esac
    check_status "Formatting Root as ${SELECTED_FS}"

    # Format Boot
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkfs.fat -F32 "${BOOT_PARTITION}"
    else
        mkfs.ext4 -F "${BOOT_PARTITION}"
    fi

    # Format Swap
    if [[ -n "$SWAP_PARTITION" ]]; then
        mkswap "${SWAP_PARTITION}"
    fi
}

select_timezone() {
    # MODIFIED: Check config
    if [[ "$USE_CONFIG" == "true" && -n "$DEFAULT_REGION" && -n "$DEFAULT_CITY" ]]; then
        info "Using Timezone from config: ${DEFAULT_REGION}/${DEFAULT_CITY}"
        return
    fi

    info "Attempting to detect your timezone automatically..."

    # 1. Try to get the timezone string (e.g., America/Toronto)
    AUTO_TZ=$(curl -fsSL --connect-timeout 5 https://ipinfo.io/timezone)

    if [[ -n "$AUTO_TZ" && "$AUTO_TZ" == *"/"* ]]; then
        DETECTED_REGION="${AUTO_TZ%/*}"
        DETECTED_CITY="${AUTO_TZ#*/}"

        # 2. Ask for confirmation with the explicit [y/N]
        if confirm "I detected your timezone as ${DETECTED_REGION}/${DETECTED_CITY}. Is this correct?"; then
            DEFAULT_REGION="$DETECTED_REGION"
            DEFAULT_CITY="$DETECTED_CITY"
            success "Timezone set to ${DEFAULT_REGION}/${DEFAULT_CITY}"
            return 0
        fi
    fi

    # 3. Fallback to manual selection
    warn "Automatic detection skipped. Manual selection required."

    regions=("America" "Europe" "Asia" "Australia" "Africa")
    echo "Select your Region:"
    select region in "${regions[@]}"; do
        if [[ -n "$region" ]]; then
            DEFAULT_REGION="$region"
            break
        fi
    done

    prompt "Enter your City (e.g., New_York, London, Berlin): " USER_CITY
    # Replace spaces with underscores for the filesystem path
    DEFAULT_CITY=$(echo "$USER_CITY" | sed 's/ /_/g')
}

mount_filesystems() {
    info "Mounting filesystems..."

    local MOUNT_SOURCE="${ROOT_PARTITION}"
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        MOUNT_SOURCE="/dev/mapper/cryptroot"
    fi

    # --- BTRFS LOGIC ---
    if [[ "$SELECTED_FS" == "btrfs" ]]; then
        info "Detected Btrfs. Creating subvolumes (@ and @home)..."

        # 1. Mount the raw root temporarily
        mount "${MOUNT_SOURCE}" /mnt

        # 2. Create subvolumes
        btrfs subvolume create /mnt/@
        btrfs subvolume create /mnt/@home

        # 3. Unmount raw root
        umount /mnt

        # 4. Mount @ as /
        mount -o compress=zstd,subvol=@ "${MOUNT_SOURCE}" /mnt

        # 5. Mount @home as /home
        mkdir -p /mnt/home
        mount -o compress=zstd,subvol=@home "${MOUNT_SOURCE}" /mnt/home

        success "Btrfs subvolumes configured."
    else
        # --- STANDARD LOGIC ---
        info "Mounting Root (${MOUNT_SOURCE}) on /mnt"
        mount "${MOUNT_SOURCE}" /mnt
    fi
    check_status "Mounting root"

    # --- BOOT PARTITION ---
    info "Mounting Boot partition ${BOOT_PARTITION} on /mnt/boot"
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot

    # --- SWAP ---
    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "${SWAP_PARTITION}"
    fi
}

install_base_system() {
    # 1. Pre-flight check
    if ! mountpoint -q /mnt; then
        error "Target /mnt is not mounted. Aborting base installation."
        return 1
    fi

    info "Installing base system packages via pacstrap..."

    # ---------------------------------------------------------
    # Hardware Detection (Microcode)
    # ---------------------------------------------------------
    local microcode_pkg=""
    local cpu_vendor
    cpu_vendor=$(grep -m1 "^vendor_id" /proc/cpuinfo | awk '{print $3}')

    case "$cpu_vendor" in
        "GenuineIntel") microcode_pkg="intel-ucode" ;;
        "AuthenticAMD") microcode_pkg="amd-ucode" ;;
    esac

    if [[ -n "$microcode_pkg" ]]; then
        info "Detected CPU vendor: ${cpu_vendor}. Adding ${microcode_pkg}."
    fi

    # ZRAM Support
    if [[ "$SWAP_TYPE" == "ZRAM" ]]; then
        info "Adding ZRAM generator to package list..."
        base_pkgs+=("zram-generator")
    fi

    # ---------------------------------------------------------
    # Package Definitions
    # ---------------------------------------------------------

    # Core system packages
    local base_pkgs=(
        "base"
        "base-devel"
        "$SELECTED_KERNEL"
        "linux-firmware"
        "grub"
        "gptfdisk"          # For partitioning tools in chroot
        "networkmanager"
        "nano"
        "vim"
        "git"
        "wget"
        "curl"
        "cryptsetup"
        "btrfs-progs"
        "xfsprogs"
        "reflector"
        "btop"
        "fastfetch"
        "man-db"
        "man-pages"
        "texinfo"
    )

    # GPU Drivers
    if [[ "$INSTALL_NVIDIA" == "true" ]]; then
        info "Adding NVIDIA drivers to installation list..."
        # nvidia-dkms is safer for custom kernels (like linux-zen)
        # lib32-nvidia-utils is needed for Steam (32-bit games)
        base_pkgs+=("nvidia-dkms" "nvidia-utils" "nvidia-settings")

        if [[ "$ENABLE_MULTILIB" == "true" || "$INSTALL_STEAM" == "true" ]]; then
            base_pkgs+=("lib32-nvidia-utils")
        fi

        # Add nvidia hook to mkinitcpio later?
        # Usually not strictly required for boot, but 'kms' hook handles modesetting.
        # However, we MUST set the kernel parameter for DRM.
    fi

    # Shell configuration
    if [[ "$INSTALL_ZSH" == "true" ]]; then
        base_pkgs+=("zsh" "zsh-completions")
    fi

    # Bootloader specific
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        base_pkgs+=("efibootmgr")
    fi

    # Add microcode if detected
    [[ -n "$microcode_pkg" ]] && base_pkgs+=("$microcode_pkg")

    # Common GUI utilities (Audio, Network, Web, remote access)
    # Used across most DEs to avoid repetition
    local common_gui_pkgs=(
        "pipewire-alsa"
        "pipewire-pulse"
        "alsa-utils"
        "flatpak"
        "firefox"
        "openssh"
    )

    # ---------------------------------------------------------
    # Desktop Environment Selection
    # ---------------------------------------------------------
    local de_pkgs=()
    local dm_service=""

    case $SELECTED_DE_INDEX in
        0) # Server
            info "Profile: Server (Headless)"
            de_pkgs+=("openssh")
            ;;
        1) # KDE Plasma
            info "Profile: KDE Plasma"
            dm_service="sddm"
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "plasma-desktop" "sddm" "konsole" "dolphin" "ark"
                "spectacle" "kate" "discover" "plasma-nm" "gwenview"
                "kcalc" "kscreen" "partitionmanager" "p7zip" "plasma-pa"
                "sddm-kcm"
            )
            ;;
        2) # GNOME
            info "Profile: GNOME"
            dm_service="gdm"
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "gnome" "gdm" "gnome-terminal" "nautilus"
                "gnome-text-editor" "gnome-control-center" "gnome-software"
                "eog" "file-roller" "gnome-tweaks"
                "gvfs-smb" "gvfs-mtp" "gvfs-afc" "gvfs-nfs" "gvfs-gphoto2"
            )
            ;;
        3) # XFCE
            info "Profile: XFCE"
            dm_service="lightdm"
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter"
                "xfce4-terminal" "thunar" "mousepad" "ristretto" "file-roller"
                "network-manager-applet"
                "gvfs" "gvfs-smb" "gvfs-mtp" "gvfs-afc" "gvfs-nfs" "gvfs-gphoto2"
                "blueman" "pavucontrol" "xdg-user-dirs"
            )
            ;;
        4) # LXQt
            info "Profile: LXQt"
            dm_service="sddm"
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "lxqt" "sddm" "qterminal" "pcmanfm-qt" "featherpad"
                "lximage-qt" "ark" "network-manager-applet"
                "openbox" "obconf-qt" "breeze-icons" "lxqt-themes"
                "gvfs" "gvfs-smb" "gvfs-mtp" "gvfs-afc" "gvfs-nfs" "gvfs-gphoto2"
            )
            ;;
        5) # MATE
            info "Profile: MATE"
            dm_service="lightdm"
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "mate" "mate-extra" "lightdm" "lightdm-gtk-greeter"
                "mate-terminal" "caja" "pluma" "eom" "engrampa"
                "network-manager-applet"
                "gvfs" "gvfs-smb" "gvfs-mtp" "gvfs-afc" "gvfs-nfs" "gvfs-gphoto2"
                "blueman" "pavucontrol" "xdg-user-dirs"
            )
            ;;
        6) # KDE Plasma (Nakildias Profile)
            info "Profile: KDE Plasma (Nakildias Custom)"
            dm_service="sddm"
            # Note: This profile has specific requirements, so we list explicit tools
            de_pkgs+=(
                "${common_gui_pkgs[@]}"
                "plasma-desktop" "sddm" "konsole" "dolphin" "ark"
                "spectacle" "kate" "discover" "plasma-nm" "gwenview"
                "kcalc" "kscreen" "partitionmanager" "p7zip" "plasma-pa"
                "bluedevil" "obs-studio" "spotify-launcher" "sddm-kcm"
                "kdenlive" "kdeconnect" "kwalletmanager" "kfind"
                "isoimagewriter" "kmail" "calindori" "ntfs-3g" "cups"
                "system-config-printer" "print-manager" "krdp" "deluge-gtk"
                "thefuck" "git-lfs" "virt-manager" "nmap" "traceroute"
                "qemu-desktop" "dnsmasq" "krdc" "plasma-browser-integration"
            )
            ;;
    esac

    # Persist the Display Manager choice for the configuration phase
    # Assuming you have a mechanism to pass variables to the chroot setup
    echo "DM_SERVICE='$dm_service'" > /tmp/arch_install_dm_choice

    echo "AUTO_LOGIN_USER='$AUTO_LOGIN_USER'" >> /tmp/arch_install_dm_choice

    # ---------------------------------------------------------
    # Optional Extras
    # ---------------------------------------------------------
    local optional_pkgs=()
    $INSTALL_STEAM   && optional_pkgs+=("steam")
    $INSTALL_DISCORD && optional_pkgs+=("discord")
    $INSTALL_UFW     && optional_pkgs+=("ufw")

    # ---------------------------------------------------------
    # Execution
    # ---------------------------------------------------------
    local all_pkgs=("${base_pkgs[@]}" "${de_pkgs[@]}" "${optional_pkgs[@]}")

    info "Total packages to install: ${#all_pkgs[@]}"

    # We use printf for a cleaner list output, avoiding the 'fold' pipe if possible,
    # or just keeping it simple.
    echo "-----------------------------------------------------"
    printf "%s " "${all_pkgs[@]}" | fold -s -w 80
    echo -e "\n-----------------------------------------------------"

    # Execute Pacstrap
    # -K initializes the keyring in the target, important for signature checking
    pacstrap -K /mnt "${all_pkgs[@]}"

    # Check exit code explicitly
    if [[ $? -eq 0 ]]; then
        success "Pacstrap completed successfully."

        # Handle the nano syntax request here via sed on the target filesystem
        # This is cleaner than doing it "later"
        if [[ -f "/mnt/etc/nanorc" ]]; then
            sed -i 's/^# include/include/' /mnt/etc/nanorc
            info "Enabled global nano syntax highlighting."
        fi
    else
        error "Pacstrap failed. Check the output above for details."
        return 1
    fi
}

configure_installed_system() {
    info "Configuring the installed system (within chroot)..."

    # Retrieve the Display Manager choice saved in the previous function
    if [ -f /tmp/arch_install_dm_choice ]; then
        source /tmp/arch_install_dm_choice
        ENABLE_DM="$DM_SERVICE"
    else
        ENABLE_DM=""
        AUTO_LOGIN_USER=""
    fi

    # Generate fstab
    info "Generating fstab..."
    # Use -U for UUIDs (recommended)
    genfstab -U /mnt >> /mnt/etc/fstab
    check_status "Generating fstab"
    # Simple check for device names which are less robust than UUIDs/LABELs
    if grep -qE '/dev/(sd|nvme|vd|mmcblk)' /mnt/etc/fstab; then
        warn "/etc/fstab seems to contain device names instead of UUIDs. Consider editing /mnt/etc/fstab manually later."
    fi
    success "fstab generated and appended to /mnt/etc/fstab."
    info "Review /mnt/etc/fstab:"
    cat /mnt/etc/fstab

    # Copy necessary host configurations into chroot environment
    info "Copying essential configuration files to chroot..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    check_status "Copying mirrorlist to /mnt"
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    check_status "Copying pacman.conf to /mnt"

    # Create chroot configuration script using Split Heredoc
    info "Creating chroot configuration script..."

    # --- PART 1: Header and Basic Setup ---
    cat <<CHROOT_HEADER > /mnt/configure_chroot.sh
#!/bin/bash
# This script runs inside the chroot environment

# Strict mode
set -e
set -o pipefail

# Variables passed from the main script
HOSTNAME="${HOSTNAME}"
ENABLE_DM="${ENABLE_DM}"
AUTO_LOGIN_USER="${AUTO_LOGIN_USER}"
ENABLE_ENCRYPTION="${ENABLE_ENCRYPTION}"
ROOT_PARTITION="${ROOT_PARTITION}"  # We need the RAW partition path (e.g. /dev/sda1) for Grub
SELECTED_FS="${SELECTED_FS}"
SWAP_TYPE="${SWAP_TYPE}"
INSTALL_STEAM=${INSTALL_STEAM}
INSTALL_ZSH=${INSTALL_ZSH}
INSTALL_UFW=${INSTALL_UFW}
INSTALL_YAY=${INSTALL_YAY}
ENABLE_MULTILIB=${ENABLE_MULTILIB}
DEFAULT_REGION="${DEFAULT_REGION}"
DEFAULT_CITY="${DEFAULT_CITY}"
PARALLEL_DL_COUNT="${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}"

# Determine Shell
USER_SHELL="/bin/bash"
if [ "$INSTALL_ZSH" == "true" ]; then
    USER_SHELL="/bin/zsh"
fi

# Chroot Logging functions
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "\${C_BLUE}\${C_BOLD}[CHROOT INFO]\${C_OFF} \$1"; }
error() { echo -e "\${C_RED}\${C_BOLD}[CHROOT ERROR]\${C_OFF} \$1"; exit 1; }
success() { echo -e "\${C_GREEN}\${C_BOLD}[CHROOT SUCCESS]\${C_OFF} \$1"; }
warn() { echo -e "\${C_YELLOW}\${C_BOLD}[CHROOT WARN]\${C_OFF} \$1"; }
check_status_chroot() {
    local status=\$?
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; fi
    return \$status
}

# --- Configuration Steps ---

info "Setting timezone to \${DEFAULT_REGION}/\${DEFAULT_CITY}..."
ln -sf "/usr/share/zoneinfo/\${DEFAULT_REGION}/\${DEFAULT_CITY}" /etc/localtime
check_status_chroot "Linking timezone"
hwclock --systohc
check_status_chroot "Setting hardware clock"
success "Timezone set."

# Enable nano syntax highlighting
info "Enabling all nano syntax highlighting..."
if [ -f /etc/nanorc ]; then
    sed -i "s/^#[[:space:]]*include/include/" /etc/nanorc
    info "Nano syntax highlighting enabled."
else
    warn "/etc/nanorc not found in chroot."
fi

info "Configuring Locale (en_US.UTF-8)..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
locale-gen
check_status_chroot "Generating locales"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
success "Locale configured."

info "Creating vconsole.conf..."
echo "KEYMAP=us" > /etc/vconsole.conf
check_status_chroot "Creating /etc/vconsole.conf"
success "vconsole.conf created."

info "Setting hostname to '\${HOSTNAME}'..."
echo "\${HOSTNAME}" > /etc/hostname
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
EOF_HOSTS
check_status_chroot "Writing /etc/hosts"
success "Hostname set."
CHROOT_HEADER

    # --- PART 2: Dynamic User Creation ---
    {
        echo ""
        echo "# --- User Configuration ---"

        # Root Account
        if [ "$ENABLE_ROOT_ACCOUNT" == "true" ]; then
            echo "info 'Setting root password...'"
            echo "echo 'root:${ROOT_PASSWORD}' | chpasswd"
            echo "check_status_chroot 'Setting root password'"
            echo "success 'Root password set.'"
        else
            echo "info 'Locking root account...'"
            echo "passwd -l root"
            echo "success 'Root account locked.'"
        fi

        # User Accounts
        for i in "${!USER_NAMES[@]}"; do
            local u="${USER_NAMES[$i]}"
            local p="${USER_PASSWORDS[$i]}"
            local s="${USER_SUDO[$i]}"

            echo "info \"Creating user '$u'...\""
            echo "useradd -m -s \${USER_SHELL} '$u'"
            echo "check_status_chroot 'Creating user $u'"
            echo "echo '$u:$p' | chpasswd"
            echo "check_status_chroot 'Setting password for $u'"

            if [ "$s" == "true" ]; then
                echo "usermod -aG wheel '$u'"
                echo "check_status_chroot 'Adding $u to wheel group'"
            fi
            echo "success \"User '$u' created.\""

            # If Zsh is installed, configure auto-run of post-install.sh
            if [ "$INSTALL_ZSH" == "true" ]; then
                echo "info \"Configuring .zshrc for '$u' to suggest post-install.sh...\""
                # Create .zshrc with auto-run logic. Use 'EOF_ZSHRC' to prevent expansion in configure_chroot.sh
                echo "cat <<'EOF_ZSHRC' >> /home/$u/.zshrc
# Auto-generated by install.sh to prompt for post-install configuration

if [ ! -f \"\$HOME/.zsh_configured\" ]; then
    echo \"\"
    echo \"-----------------------------------------------------------------\"
    echo \"Do you want to configure Zsh to make your terminal look beautiful?\"
    echo \"This will run the ~/Scripts/post-install.sh script.\"
    echo \"-----------------------------------------------------------------\"
    read -r \"response?Run configuration now? [y/N] \"
    if [[ \"\$response\" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        if [ -f \"\$HOME/Scripts/post-install.sh\" ]; then
            \"\$HOME/Scripts/post-install.sh\"
        else
            echo \"Error: ~/Scripts/post-install.sh not found.\"
        fi
    fi
    # Mark as checked so it doesn't ask again
    touch \"\$HOME/.zsh_configured\"
fi
EOF_ZSHRC"
                echo "chown '$u:$u' /home/$u/.zshrc"
            fi
        done

        # Root Zsh Configuration (if enabled)
        if [ "$INSTALL_ZSH" == "true" ] && [ "$ENABLE_ROOT_ACCOUNT" == "true" ]; then
             echo "info \"Configuring .zshrc for root...\""
             echo "cat <<'EOF_ZSHRC' >> /root/.zshrc
# Auto-generated by install.sh

if [ ! -f \"\$HOME/.zsh_configured\" ]; then
    echo \"\"
    echo \"-----------------------------------------------------------------\"
    echo \"Do you want to configure Zsh for ROOT?\"
    echo \"This will run the ~/Scripts/post-install.sh script.\"
    echo \"-----------------------------------------------------------------\"
    read -r \"response?Run configuration now? [y/N] \"
    if [[ \"\$response\" =~ ^([yY][eE][sS]|[yY])$ ]]; then
        if [ -f \"\$HOME/Scripts/post-install.sh\" ]; then
            \"\$HOME/Scripts/post-install.sh\"
        else
            echo \"Error: ~/Scripts/post-install.sh not found.\"
        fi
    fi
    touch \"\$HOME/.zsh_configured\"
fi
EOF_ZSHRC"
        fi

        echo ""
    } >> /mnt/configure_chroot.sh

    # --- PART 3: Tail (Sudoers, Pacman, Services) ---
    cat <<CHROOT_TAIL >> /mnt/configure_chroot.sh
info "Configuring sudo for 'wheel' group..."
if grep -q -E '^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    sed -i -E 's/^#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)/\1/' /etc/sudoers
    check_status_chroot "Uncommenting wheel group in sudoers"
    success "Sudo configured for 'wheel' group."
elif grep -q -E '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    warn "'wheel' group already uncommented in sudoers. No changes made."
else
    error "Could not find the wheel group line in /etc/sudoers to uncomment. Manual configuration needed."
fi

# Ensure Pacman config (ParallelDownloads, Color, VerbosePkgLists, Multilib)
info "Ensuring Pacman configuration inside chroot..."
sed -i -E \
    -e 's/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = '"\${PARALLEL_DL_COUNT}"'/' \
    -e 's/^[[:space:]]*(ParallelDownloads).*/\1 = '"\${PARALLEL_DL_COUNT}"'/' \
    /etc/pacman.conf
if ! grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
    echo "ParallelDownloads = \${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
fi
sed -i -E \
    -e 's/^[[:space:]]*#[[:space:]]*(Color)/\1/' \
    /etc/pacman.conf
if ! grep -q -E "^[[:space:]]*Color" /etc/pacman.conf; then
    echo "Color" >> /etc/pacman.conf
fi
sed -i -E \
    -e 's/^[[:space:]]*#[[:space:]]*(VerbosePkgLists)/\1/' \
    /etc/pacman.conf
if ! grep -q -E "^[[:space:]]*VerbosePkgLists" /etc/pacman.conf; then
    echo "VerbosePkgLists" >> /etc/pacman.conf
fi

if [[ "\${INSTALL_STEAM}" == "true" ]] || [[ "\${ENABLE_MULTILIB}" == "true" ]]; then
    info "Ensuring Multilib repository is enabled in chroot pacman.conf..."
    sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
    check_status_chroot "Ensuring multilib is enabled in chroot pacman.conf"
fi
success "Pacman configuration verified."

# --- ZRAM CONFIGURATION ---
    if [[ "${SWAP_TYPE}" == "ZRAM" ]]; then
        info "Configuring ZRAM..."
        # Create config file for zram-generator
        cat <<EOF_ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = zstd
EOF_ZRAM
        check_status_chroot "Creating ZRAM config"
        success "ZRAM configured (Cap: 8GB, Algo: zstd)."
    fi

# --- CONFIGURE MKINITCPIO (Hooks) ---
info "Configuring mkinitcpio hooks..."
if [[ "\${ENABLE_ENCRYPTION}" == "true" ]]; then
    # Add 'encrypt' hook before 'filesystems'
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    info "Added 'encrypt' hook to mkinitcpio.conf"
else
    # Standard hooks
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi

# Regenerate initramfs
info "Generating initramfs..."
mkinitcpio -P
check_status_chroot "mkinitcpio generation"

# --- CONFIGURE BOOTLOADER PARAMETERS ---
if [[ "\${ENABLE_ENCRYPTION}" == "true" ]]; then
    # Get UUID of the RAW encrypted partition
    CRYPT_UUID=\$(blkid -s UUID -o value "\${ROOT_PARTITION}")

    # Kernel parameters for GRUB
    # cryptdevice=UUID=<uuid>:cryptroot root=/dev/mapper/cryptroot
    GRUB_CRYPT_PARAMS="cryptdevice=UUID=\${CRYPT_UUID}:cryptroot root=/dev/mapper/cryptroot"

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet \${GRUB_CRYPT_PARAMS}\"|" /etc/default/grub

    # Kernel parameters for systemd-boot are handled in the install_bootloader function outside chroot
    # but we store them here just in case specific chroot actions need them.
fi

if [[ "\${SELECTED_FS}" == "btrfs" ]]; then
    GRUB_PARAMS="\${GRUB_PARAMS} rootflags=subvol=@"
fi

if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    # Add nvidia-drm.modeset=1 to GRUB (Essential for Wayland/KDE)
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
fi

info "Enabling NetworkManager service..."
systemctl enable NetworkManager.service
check_status_chroot "Enabling NetworkManager service"
success "NetworkManager enabled."

if [[ -n "\${ENABLE_DM}" ]]; then
    info "Enabling Display Manager service (\${ENABLE_DM})..."
    systemctl enable "\${ENABLE_DM}.service"
    check_status_chroot "Enabling \${ENABLE_DM} service"
    success "\${ENABLE_DM} enabled."
    # --- Configure Auto-Login ---
    if [[ -n "\${AUTO_LOGIN_USER}" ]] && [[ -n "\${ENABLE_DM}" ]]; then
        info "Configuring auto-login for user '\${AUTO_LOGIN_USER}'..."

        case "\${ENABLE_DM}" in
            "sddm")
                # SDDM needs the EXACT session filename.

                target_session=""

                # --- PRIORITY CHECK: Look for known DEs explicitly first ---
                # This prevents picking "openbox.desktop" by mistake when installing LXQt.
                if [ -f /usr/share/xsessions/lxqt.desktop ]; then
                    target_session="lxqt"
                elif [ -f /usr/share/wayland-sessions/plasma.desktop ]; then
                    target_session="plasma"
                elif [ -f /usr/share/xsessions/plasma.desktop ]; then
                    target_session="plasma"
                fi

                # --- FALLBACK CHECK: Blind search if nothing above was found ---
                if [[ -z "\$target_session" ]]; then
                    # Safe Mode: Temporarily disable strict error checking for the search
                    set +e
                    set +o pipefail

                    # 1. Try Wayland
                    if [ -d /usr/share/wayland-sessions ]; then
                        target_session=\$(find /usr/share/wayland-sessions -name "*.desktop" 2>/dev/null | head -n 1 | xargs -r basename -s .desktop)
                    fi

                    # 2. Try X11
                    if [[ -z "\$target_session" ]] && [ -d /usr/share/xsessions ]; then
                        target_session=\$(find /usr/share/xsessions -name "*.desktop" 2>/dev/null | head -n 1 | xargs -r basename -s .desktop)
                    fi

                    # Re-enable strict checking
                    set -e
                    set -o pipefail
                fi

                info "Detected SDDM Session: \$target_session"

                # Write the config
                mkdir -p /etc/sddm.conf.d
                {
                    echo "[Autologin]"
                    echo "User=\${AUTO_LOGIN_USER}"
                    echo "Session=\${target_session}"
                    echo "Relogin=false"
                } > /etc/sddm.conf.d/autologin.conf
                ;;

            "gdm")
                # GNOME (GDM)
                if ! grep -q "\[daemon\]" /etc/gdm/custom.conf; then
                    echo "[daemon]" >> /etc/gdm/custom.conf
                fi
                # Remove old settings if they exist to avoid duplication
                sed -i "/AutomaticLogin/d" /etc/gdm/custom.conf
                sed -i "/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=\${AUTO_LOGIN_USER}" /etc/gdm/custom.conf
                ;;

            "lightdm")
                # XFCE/MATE (LightDM) configuration
                # FIX: Create the 'autologin' group and add the user.
                groupadd -rf autologin
                gpasswd -a "${AUTO_LOGIN_USER}" autologin

                # FIX: Use a drop-in config file.
                # NOTE: We use \$ (escaped) for variables calculated INSIDE the chroot.

                dm_session_name=""
                if pacman -Qq xfce4-session >/dev/null 2>&1; then dm_session_name="xfce"; fi
                if pacman -Qq mate-session-manager >/dev/null 2>&1; then dm_session_name="mate"; fi

                mkdir -p /etc/lightdm/lightdm.conf.d
                {
                    echo "[Seat:*]"
                    echo "autologin-user=${AUTO_LOGIN_USER}"
                    # We must escape the $ here so it checks the variable inside the script, not the installer
                    if [[ -n "\$dm_session_name" ]]; then
                        echo "autologin-session=\$dm_session_name"
                    fi
                } > /etc/lightdm/lightdm.conf.d/autologin.conf

                success "Configured LightDM Autologin for user: ${AUTO_LOGIN_USER}"
                ;;
        esac
        success "Auto-login configured for \${ENABLE_DM} (User: \${AUTO_LOGIN_USER})."
    fi
else
    info "No Display Manager to enable (Server install or manual setup selected)."
fi

if pacman -Qs openssh &>/dev/null; then
    info "OpenSSH package found, enabling sshd service..."
    systemctl enable sshd.service
    success "sshd enabled."
fi
if pacman -Q cups &>/dev/null; then
    info "cups package found, enabling cups service..."
    systemctl enable cups.service
    success "cups enabled."
fi
if pacman -Q bluez &>/dev/null; then
    info "bluez package found, enabling bluetooth service..."
    systemctl enable bluetooth.service
    success "bluez enabled."
fi
if pacman -Q libvirt &>/dev/null; then
    info "libvirt package found, enabling libvirtd service..."
    systemctl enable libvirtd.service
    success "libvirtd enabled."
fi

# Enable UFW
if [[ "${INSTALL_UFW}" == "true" ]]; then
    info "Enabling UFW Firewall..."
    systemctl enable ufw.service
    check_status_chroot "Enabling UFW service"
    success "UFW enabled."
fi

# Install Yay (AUR Helper) - Using yay-bin for speed
if [[ "${INSTALL_YAY}" == "true" ]]; then
    info "Installing Yay (AUR Helper)..."

    # 1. Global Optimization (Good for the user later)
    # We set makepkg to use all cores for future AUR builds
    # $(nproc) is fine here without escape, we want it calculated now
    sed -i "s/^#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf

    # 2. Locate a non-root user for building
    # ESCAPED: We want these to run inside the chroot, not now
    start_dir=\$(pwd)
    cd /home
    BUILD_USER=\$(find . -maxdepth 1 -mindepth 1 -type d ! -name "lost+found" -printf "%f\n" | head -n 1)

    if [[ -n "\$BUILD_USER" ]]; then
        info "Using user '\$BUILD_USER' to install yay-bin..."
        cd "/home/\$BUILD_USER"

        # 3. Clone yay-bin (Pre-compiled binary)
        # We use yay-bin to avoid installing 'go' compiler (saves time and ~400MB)
        # ESCAPED: \$BUILD_USER
        sudo -u "\$BUILD_USER" git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin

        # 4. Package it (No compilation needed, just packaging)
        # --noconfirm: accept defaults
        sudo -u "\$BUILD_USER" makepkg --noconfirm
        check_status_chroot "Packaging yay-bin"

        # 5. Install the resulting package as Root
        info "Installing yay-bin package..."
        pacman -U --noconfirm *.pkg.tar.zst
        check_status_chroot "Installing yay-bin"

        # Cleanup
        cd ..
        rm -rf yay-bin
        success "Yay installed successfully (Binary version)."
    else
        warn "No non-root user found to build Yay. Skipping installation."
    fi
    # ESCAPED: \$start_dir
    cd "\$start_dir"
fi

info "Updating initial ramdisk environment (mkinitcpio)..."
# mkinitcpio -P
info "Skipping redundant mkinitcpio (it was run during package installation)."

success "Chroot configuration script finished successfully."
CHROOT_TAIL

    check_status "Creating chroot configuration script"
    chmod +x /mnt/configure_chroot.sh
    check_status "Setting execute permissions on chroot script"

    info "Executing configuration script inside chroot environment..."
    arch-chroot /mnt /configure_chroot.sh
    check_status "Executing chroot configuration script"

    info "Removing chroot configuration script..."
    rm /mnt/configure_chroot.sh
    check_status "Removing chroot script"

    success "System configuration inside chroot complete."
}

install_bootloader() {
    info "Installing ${SELECTED_BOOTLOADER} bootloader..."

    # Re-detect CPU vendor for Microcode logic (needed for config entries)
    local cpu_vendor=$(grep -m1 "^vendor_id" /proc/cpuinfo | awk '{print $3}')
    local microcode_img=""
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then microcode_img="/intel-ucode.img"
    elif [[ "$cpu_vendor" == "AuthenticAMD" ]]; then microcode_img="/amd-ucode.img"; fi

    # ------------------------------------
    # OPTION A: GRUB (BIOS or UEFI)
    # ------------------------------------
    if [[ "$SELECTED_BOOTLOADER" == "grub" ]]; then
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            info "Installing GRUB for UEFI..."
            arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
        else
            info "Installing GRUB for BIOS..."
            arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"
        fi

        info "Generating GRUB config..."
        arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
        check_status "GRUB installation"

    # ------------------------------------
    # OPTION B: systemd-boot (UEFI Only)
    # ------------------------------------
    elif [[ "$SELECTED_BOOTLOADER" == "systemd-boot" ]]; then
        info "Installing systemd-boot..."

        # 1. Install the bootloader binaries to ESP
        arch-chroot /mnt bootctl install
        check_status "systemd-boot installation"

        # 2. Configure loader.conf (The main menu settings)
        # timeout 3: Wait 3 seconds
        # default arch.conf: Default to the entry we are about to make
        echo "default arch.conf" > /mnt/boot/loader/loader.conf
        echo "timeout 3" >> /mnt/boot/loader/loader.conf
        echo "console-mode max" >> /mnt/boot/loader/loader.conf
        # 'console-mode max' fixes resolution issues on some UEFI screens

        # 3. Create the Boot Entry
        # We need the PARTUUID or UUID of the ROOT partition.
        # Since we are scripting, UUID is robust.
        local root_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")

        info "Creating boot entry for kernel: $SELECTED_KERNEL"

        # Determine kernel image names based on selection
        # linux -> vmlinuz-linux / initramfs-linux.img
        # linux-lts -> vmlinuz-linux-lts / initramfs-linux-lts.img
        local vmlinuz="vmlinuz-${SELECTED_KERNEL}"
        local initramfs="initramfs-${SELECTED_KERNEL}.img"

        # Create the entry file
        cat <<EOF_ENTRY > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /${vmlinuz}
EOF_ENTRY

        # Append Microcode line if detected
        if [[ -n "$microcode_img" ]]; then
            echo "initrd  ${microcode_img}" >> /mnt/boot/loader/entries/arch.conf
        fi

        # Logic to determine ROOT line for systemd-boot
        local options_line="options root=UUID=${root_uuid} rw"

        if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
            local raw_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")
            options_line="options cryptdevice=UUID=${raw_uuid}:cryptroot root=/dev/mapper/cryptroot rw"
        fi

        if [[ "$SELECTED_FS" == "btrfs" ]]; then
            options_line="${options_line} rootflags=subvol=@"
        fi

        # Append Initramfs and Options
        cat <<EOF_OPTIONS >> /mnt/boot/loader/entries/arch.conf
initrd  /${initramfs}
${options_line}
EOF_OPTIONS

        # 4. Optional: Create a fallback entry (Good practice)
        cp /mnt/boot/loader/entries/arch.conf /mnt/boot/loader/entries/arch-fallback.conf
        sed -i "s/Arch Linux/Arch Linux (Fallback)/" /mnt/boot/loader/entries/arch-fallback.conf
        sed -i "s/${initramfs}/initramfs-${SELECTED_KERNEL}-fallback.img/" /mnt/boot/loader/entries/arch-fallback.conf

        success "systemd-boot configured with entries for ${SELECTED_KERNEL}."
    fi
}

# --- KEXEC ---
try_kexec_boot() {
    # 1. Check the preference set at the start of the script
    if [[ "$ENABLE_KEXEC" != "true" ]]; then
        return 0
    fi

    info "Permission granted. Preparing for immediate kernel switch (kexec)..."

    # 2. Install kexec-tools on the Live ISO environment
    info "Installing kexec-tools..."
    pacman -Sy --noconfirm kexec-tools >/dev/null 2>&1
    if [ $? -ne 0 ]; then
        error "Failed to install kexec-tools. Standard reboot required."
        return 1
    fi

    # 3. Determine Kernel paths and Root UUID
    local kernel_img="/mnt/boot/vmlinuz-${SELECTED_KERNEL}"
    local initrd_img="/mnt/boot/initramfs-${SELECTED_KERNEL}.img"
    local root_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")

    if [[ ! -f "$kernel_img" ]]; then
        error "Kernel image not found at $kernel_img. Cannot kexec."
        return 1
    fi

    # --- CORRECTION START ---
    # 4. Prepare Kernel Parameters based on Encryption
    local kexec_args=""
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        # If encrypted, we must unlock the UUID and mount the mapper
        kexec_args="cryptdevice=UUID=${root_uuid}:cryptroot root=/dev/mapper/cryptroot rw loglevel=3 quiet"
    else
        # If standard, just mount the UUID
        kexec_args="root=UUID=${root_uuid} rw loglevel=3 quiet"
    fi

    if [[ "$SELECTED_FS" == "btrfs" ]]; then
        kexec_args="${kexec_args} rootflags=subvol=@"
    fi

    # 5. Load the new kernel into RAM
    info "Loading new kernel into memory..."
    kexec -l "$kernel_img" --initrd="$initrd_img" --append="$kexec_args"
    # --- CORRECTION END ---

    check_status "Loading kernel (kexec -l)"

    # 6. Unmount filesystems cleanly
    info "Unmounting filesystems to ensure data safety..."
    sync
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null

    # Close the LUKS container if it exists
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        cryptsetup close cryptroot &>/dev/null || true
    fi

    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
        swapoff "${SWAP_PARTITION}" &>/dev/null
    fi

    # 7. Execute the jump
    success "Jumping to the new kernel now! See you on the other side."
    sleep 2

    kexec -e

    error "kexec failed to execute."
    exit 1
}

final_steps() {

    if [ ${#USER_NAMES[@]} -gt 0 ]; then
        echo "Copying post-install.sh and other scripts to all user home directories."
        for user in "${USER_NAMES[@]}"; do
            echo "Processing user: ${user}"
            mkdir -p "/mnt/home/${user}/Scripts"
            # Ensure scripts are executable before copying
            chmod +x ./Scripts/*
            cp ./Scripts/* "/mnt/home/${user}/Scripts/"
            # Fix permissions
            arch-chroot /mnt chown -R "${user}:${user}" "/home/${user}/Scripts"
            echo "Copied scripts to /home/${user}/Scripts."
        done
    else
        warn "No users created. Skipping script copy to home directory."
    fi

    # Copy scripts for Root user if enabled
    if [ "$ENABLE_ROOT_ACCOUNT" == "true" ]; then
        echo "Copying scripts to /root/Scripts for Root user."
        mkdir -p "/mnt/root/Scripts"
        chmod +x ./Scripts/*
        cp ./Scripts/* "/mnt/root/Scripts/"
    fi

    # --- Try Experimental Boot ---
    try_kexec_boot

    success "Arch Linux installation process finished!"
    info "It is strongly recommended to review the installed system before rebooting."
    info "You can use 'arch-chroot /mnt' to enter the installed system and check configurations (e.g., /etc/fstab, users, services)."
    warn "Ensure you remove the installation medium (USB/CD/ISO) before rebooting."

    info "Attempting final unmount of filesystems..."
    sync # Sync filesystem buffers before unmounting
    # Attempt recursive unmount, use -l for lazy unmount as fallback, ignore errors
    umount -R /mnt/boot &>/dev/null || umount -l /mnt/boot &>/dev/null || true
    umount -R /mnt &>/dev/null || umount -l /mnt &>/dev/null || true
    # Deactivate swap if it was used and variable is non-empty
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
        swapoff "${SWAP_PARTITION}" &>/dev/null || true
    fi
    success "Attempted unmount and swapoff. Verify with 'lsblk' or 'mount'."

    echo -e "${C_GREEN}${C_BOLD}"
    echo "----------------------------------------------------"
    echo " Installation finished at $(date)."
    # Calculate duration
    END_TIME=$(date +%s)
    # Check if START_TIME is set (it might not be if script failed early, but trap calls cleanup not final_steps)
    if [[ -n "$START_TIME" ]]; then
        DURATION=$((END_TIME - START_TIME))
        # Format duration (H:M:S)
        HOURS=$((DURATION / 3600))
        MINUTES=$(( (DURATION % 3600) / 60 ))
        SECONDS=$((DURATION % 60))

        # Build readable string
        TIME_STR=""
        [[ $HOURS -gt 0 ]] && TIME_STR+="${HOURS}h "
        [[ $MINUTES -gt 0 ]] && TIME_STR+="${MINUTES}m "
        TIME_STR+="${SECONDS}s"

        echo " Installation took: ${TIME_STR}"
    fi

    echo " You can now type 'reboot' or 'shutdown now'."
    echo " Thank you for using this script!"
    echo "----------------------------------------------------"
    echo -e "${C_OFF}"
    INSTALL_SUCCESS="true"
}

# --- Run the main function ---
main

# Explicitly exit with success code if main finishes without errors
exit 0
