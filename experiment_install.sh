#!/bin/bash

# Arch Linux Installation Script - Enhanced
# --- Configuration ---
SCRIPT_VERSION="2.3" # Incremented version for new features
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
# Removed default timezone - will be prompted

# --- Helper Functions ---

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
info() { echo -e "${C_BLUE}${C_BOLD}[INFO]${C_OFF} $1"; }
warn() { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_OFF} $1"; }
error() { echo -e "${C_RED}${C_BOLD}[ERROR]${C_OFF} $1"; }
success() { echo -e "${C_GREEN}${C_BOLD}[SUCCESS]${C_OFF} $1"; }
# Standard prompt - reads into the variable name passed as $2
prompt() { read -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} $1")" "$2"; }
confirm() {
    while true; do
        # Use direct read for confirmation prompt
        read -p "$(echo -e "${C_YELLOW}${C_BOLD}[CONFIRM]${C_OFF} ${1} [y/N]: ")" yn
        case "${yn,,}" in # Convert to lowercase
            y|yes) return 0 ;;
            n|no|"") return 1 ;; # Default to No if Enter is pressed
            *) error "Please answer yes or no." ;;
        esac
    done
}

# Check command success
check_status() {
    local status=$? # Capture status immediately
    if [ $status -ne 0 ]; then
        error "Command failed with status $status: $1"
        # Optional: Add cleanup logic here if needed
        exit 1
    fi
    # Return the original status if needed elsewhere, though typically not used after this check
    return $status
}

# Exit handler
trap 'cleanup' EXIT SIGHUP SIGINT SIGTERM
cleanup() {
    error "--- SCRIPT INTERRUPTED OR FAILED ---"
    info "Performing cleanup..."
    # Attempt to unmount everything in reverse order in case of script failure
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    # Deactivate swap if it was activated and variable exists
    # Use parameter expansion to check if variable is set and not empty
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null
    info "Cleanup finished. If the script failed, some resources might still be mounted/active."
    info "Check with 'lsblk' and 'mount'."
    # Reset terminal colors
    echo -e "${C_OFF}"
}

# --- Script Logic ---

main() {
    # Initial setup
    setup_environment

    # Pre-installation checks
    check_boot_mode
    check_internet

    # User configuration gathering
    configure_keyboard_layout # NEW: Select keyboard layout early
    configure_timezone        # NEW: Select timezone interactively
    select_disk
    configure_partitioning    # Determines PART_PREFIX correctly
    configure_locale          # NEW: Select locale
    configure_hostname_user
    select_kernel
    select_desktop_environment
    select_optional_packages

    # Perform installation steps
    configure_mirrors          # Includes multilib logic for live env
    partition_and_format
    mount_filesystems
    install_base_system        # Includes base, kernel, DE, optional packages
    configure_installed_system # Chroot configuration (includes multilib logic again)
    install_bootloader
    install_oh_my_zsh          # Optional

    # Finalization
    final_steps
}

setup_environment() {
    # Exit immediately if a command exits with a non-zero status.
    set -e
    # Treat unset variables as an error when substituting.
    # set -u # Can be too strict during development/interactive parts
    # Cause pipelines to return the exit status of the last command that failed.
    set -o pipefail

    info "Starting Arch Linux Installation Script v${SCRIPT_VERSION}"
    info "Current Time: $(date)"
}

check_boot_mode() {
    info "Checking boot mode..."
    if [ -d "/sys/firmware/efi/efivars" ]; then
        BOOT_MODE="UEFI"
        success "System booted in UEFI mode."
    else
        BOOT_MODE="BIOS"
        success "System booted in Legacy BIOS mode."
        warn "Legacy BIOS mode detected. Installation will use MBR/BIOS boot."
    fi
    confirm "Proceed with ${BOOT_MODE} installation?" || exit 0
}

check_internet() {
    info "Checking internet connectivity..."
    # Use timeout to prevent long hangs if ping fails weirdly
    if timeout 5 ping -c 1 archlinux.org &> /dev/null; then
        success "Internet connection available."
    else
        error "No internet connection detected. Please connect to the internet and restart the script."
        exit 1
    fi
}

# NEW Function: Configure Keyboard Layout
configure_keyboard_layout() {
    info "Configuring keyboard layout..."
    info "Available console keymaps are usually in /usr/share/kbd/keymaps/"
    info "Example: us, uk, de-latin1, fr-azerty, cf (Canadian French)"
    while true; do
        prompt "Enter console keyboard layout (e.g., us, cf): " KEYMAP
        if loadkeys "${KEYMAP}" &>/dev/null; then
            success "Console keymap set to '${KEYMAP}' for this session."
            break
        else
            error "Invalid keymap '${KEYMAP}'. Please check available maps and try again."
        fi
    done

    # Simplified X11 layout setting (often matches console or is a variant)
    info "For the graphical environment (X11), the layout often matches the console."
    info "Sometimes variants exist (e.g., 'fr' for console, 'fr' or 'fr(oss)' for X11)."
    prompt "Enter X11 keyboard layout [default: ${KEYMAP}]: " X11_KEYMAP
    X11_KEYMAP=${X11_KEYMAP:-$KEYMAP} # Default to console keymap if empty
    info "X11 keyboard layout set to '${X11_KEYMAP}'."
}

# NEW Function: Configure Timezone Interactively
configure_timezone() {
    info "Configuring timezone..."
    info "You will be guided through timezone selection."
    # tzselect is interactive, no need for loops here usually
    # Capture the output of tzselect to get the selected zone
    # We need to run tzselect in a way that its output can be captured.
    # This is tricky as tzselect is interactive. Let's guide the user.
    warn "Please use the following interactive tool to select your timezone."
    warn "Note down the selected timezone (e.g., America/Toronto)."
    tzselect
    check_status "Running tzselect" # Check if tzselect itself ran okay

    while true; do
        prompt "Enter the timezone selected above (e.g., America/Toronto): " SELECTED_TIMEZONE
        if [[ -f "/usr/share/zoneinfo/${SELECTED_TIMEZONE}" ]]; then
            # Extract Region/City for later use if needed (though SELECTED_TIMEZONE is primary)
            TIMEZONE_REGION=$(dirname "$SELECTED_TIMEZONE")
            TIMEZONE_CITY=$(basename "$SELECTED_TIMEZONE")
            success "Timezone set to: ${SELECTED_TIMEZONE}"
            break
        else
           error "Invalid timezone '${SELECTED_TIMEZONE}'. Please ensure it exists in /usr/share/zoneinfo/ and matches the output from tzselect."
        fi
    done
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
            # Extract just the name (e.g., /dev/sda), which already includes /dev/
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

    # Wipe existing signatures and partition table
    info "Wiping existing signatures and partition table on ${TARGET_DISK}..."
    # Add sync before and after wiping operations for safety
    sync
    # Try sgdisk first, then wipefs as fallback. Ignore errors if already clean.
    sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true
    sync
    check_status "Wiping disk ${TARGET_DISK}"
    # Reread partition table
    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 2 # Give kernel a moment to catch up
    success "Disk ${TARGET_DISK} wiped."
}

configure_partitioning() {
    info "Configuring partition layout for ${BOOT_MODE} mode."

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

    # Swap Partition Size (Optional)
    while true; do
        # Suggest swap size based on RAM? Could be complex. Ask directly.
        prompt "Enter Swap size (e.g., 4G, leave blank for NO swap): " SWAP_SIZE_INPUT
        if [[ -z "$SWAP_SIZE_INPUT" ]]; then
            SWAP_PART_SIZE=""
            info "No swap partition will be created."
            break
        elif [[ "$SWAP_SIZE_INPUT" =~ ^[0-9]+[MG]$ ]]; then
            SWAP_PART_SIZE=$SWAP_SIZE_INPUT
            info "Swap partition size set to: ${SWAP_PART_SIZE}"
            break
        else
            error "Invalid format. Use number followed by M or G (e.g., 4G, 512M) or leave blank."
        fi
    done

    # Partition Naming Convention (e.g., /dev/sda1 vs /dev/nvme0n1p1)
    # TARGET_DISK already contains /dev/ prefix (e.g. /dev/vda)
    if [[ "$TARGET_DISK" == *nvme* || "$TARGET_DISK" == *mmcblk* ]]; then
        # For nvme/mmcblk disks like /dev/nvme0n1, /dev/mmcblk0 partitions are /dev/nvme0n1p1, /dev/mmcblk0p1 etc.
        PART_PREFIX="${TARGET_DISK}p"
    else
        # For SATA/SCSI/IDE disks like /dev/sda, partitions are /dev/sda1, sda2 etc.
        PART_PREFIX="${TARGET_DISK}"
    fi
    # Now PART_PREFIX will correctly form /dev/sda or /dev/nvme0n1p when partition number is added
    info "Partition name prefix determined: ${PART_PREFIX}" # Debugging info
}

# NEW Function: Configure Locale
configure_locale() {
    info "Configuring system language (locale)..."
    info "Common choices: en_US.UTF-8, en_GB.UTF-8, en_CA.UTF-8, fr_FR.UTF-8, fr_CA.UTF-8, de_DE.UTF-8, es_ES.UTF-8"
    # List some common locales from /etc/locale.gen
    info "Examples from /etc/locale.gen:"
    grep -E '^[a-z]{2}_[A-Z]{2}\.UTF-8' /etc/locale.gen | head -n 10 | sed 's/^/# /'

    while true; do
        prompt "Enter the desired locale [default: en_US.UTF-8]: " SELECTED_LOCALE
        SELECTED_LOCALE=${SELECTED_LOCALE:-"en_US.UTF-8"}
        # Check if the locale format is roughly correct (e.g., xx_XX.UTF-8)
        if [[ "$SELECTED_LOCALE" =~ ^[a-z]{2}_[A-Z]{2}\.UTF-8$ ]]; then
            # Check if the line exists (commented or uncommented) in locale.gen
            if grep -q -E "^#?[[:space:]]*${SELECTED_LOCALE}" /etc/locale.gen; then
                # Extract LANG part if needed, though SELECTED_LOCALE is usually sufficient
                LANG_SETTING=$(echo "$SELECTED_LOCALE" | cut -d'.' -f1)
                info "Selected locale: ${SELECTED_LOCALE}"
                info "LANG setting will be: ${LANG_SETTING}"
                break
            else
                error "Locale format seems correct, but '${SELECTED_LOCALE}' was not found in /etc/locale.gen."
                error "Please ensure you choose a locale listed in that file."
            fi
        else
            error "Invalid locale format. Please use the format 'language_TERRITORY.UTF-8' (e.g., en_US.UTF-8)."
        fi
    done
}


configure_hostname_user() {
    info "Configuring system identity..."
    while true; do
        prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
        # Basic validation: not empty, no spaces, no quotes
        if [[ -n "$HOSTNAME" && ! "$HOSTNAME" =~ [[:space:]\'\"] ]]; then
            info "Hostname set to: ${HOSTNAME}"
            break
        else
            error "Hostname cannot be empty and should not contain spaces or quotes."
        fi
    done

    while true; do
        prompt "Enter username for the primary user: " USERNAME
        # Basic validation: not empty, no spaces, no quotes, not root
        if [[ -n "$USERNAME" && ! "$USERNAME" =~ [[:space:]\'\"] && "$USERNAME" != "root" ]]; then
            info "Username set to: ${USERNAME}"
            break
        else
            error "Username cannot be empty, 'root', and should not contain spaces or quotes."
        fi
    done

    # --- Password Input (Uses direct read -s -p) ---
    info "Setting password for user '${USERNAME}'."
    while true; do
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Enter password for user '${USERNAME}': ")" USER_PASSWORD
        echo
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Confirm password for user '${USERNAME}': ")" USER_PASSWORD_CONFIRM
        echo

        if [[ -z "$USER_PASSWORD" ]]; then
            error "Password cannot be empty. Please try again."
            continue
        fi

        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then
            success "Password for user '${USERNAME}' confirmed."
            break
        else
            error "Passwords do not match. Please try again."
        fi
    done

    info "Setting password for the root user."
    while true; do
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Enter password for the root user: ")" ROOT_PASSWORD
        echo
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Confirm root password: ")" ROOT_PASSWORD_CONFIRM
        echo

        if [[ -z "$ROOT_PASSWORD" ]]; then
            error "Root password cannot be empty. Please try again."
            continue
        fi

        if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
            success "Password for root user confirmed."
            break
        else
            error "Root passwords do not match. Please try again."
        fi
    done
}

select_kernel() {
    info "Selecting Kernel..."
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

select_desktop_environment() {
    info "Selecting Desktop Environment or Server..."
    desktops=(
        "Server (No GUI)"
        "KDE Plasma"
        "GNOME"
        "XFCE"
        "LXQt"
        "MATE"
    )
    echo "Available environments:"
    select de_choice in "${desktops[@]}"; do
        if [[ -n "$de_choice" ]]; then
            SELECTED_DE_NAME=$de_choice
            SELECTED_DE_INDEX=$((REPLY - 1)) # Store index (0-based)
            info "Selected environment: ${C_BOLD}${SELECTED_DE_NAME}${C_OFF}"
            # Set flag if a DE was chosen (index > 0)
            INSTALL_DESKTOP_ENV=false
            if [[ $SELECTED_DE_INDEX -gt 0 ]]; then
                INSTALL_DESKTOP_ENV=true
            fi
            break
        else
            error "Invalid selection."
        fi
    done
}

select_optional_packages() {
    info "Optional Packages..."
    INSTALL_STEAM=false
    INSTALL_DISCORD=false
    # Add more optional packages here if desired

    if confirm "Install Steam? (Requires Multilib repository)"; then
        INSTALL_STEAM=true
        info "Steam will be installed."
    fi

    if confirm "Install Discord?"; then
        INSTALL_DISCORD=true
        info "Discord will be installed."
    fi

    # Example: Add another optional package
    # if confirm "Install LibreOffice (office suite)?"; then
    #     INSTALL_LIBREOFFICE=true
    #     info "LibreOffice will be installed."
    # fi
}

configure_mirrors() {
    info "Configuring Pacman mirrors for optimal download speed..."
    warn "This may take a few moments."

    # Backup original mirrorlist
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    check_status "Backing up mirrorlist"

    # Getting current country based on IP for reflector (requires curl)
    REFLECTOR_COUNTRY_CODE=""
    info "Attempting to detect country for mirror selection..."
    # Increased timeout slightly
    if detected_code=$(curl -s --connect-timeout 7 ipinfo.io/country); then
         if [[ -n "$detected_code" ]] && [[ ${#detected_code} -eq 2 ]]; then
            if confirm "Detected country code: ${detected_code}. Use it for reflector?"; then
                REFLECTOR_COUNTRY_CODE="$detected_code"
                info "Using detected country code: ${REFLECTOR_COUNTRY_CODE}."
            else
                 prompt "Enter desired 2-letter country code (e.g., US, CA, DE) or leave blank for worldwide: " MANUAL_COUNTRY_CODE
                 if [[ -n "$MANUAL_COUNTRY_CODE" ]]; then
                     REFLECTOR_COUNTRY_CODE="$MANUAL_COUNTRY_CODE"
                     info "Using manually entered country code: ${REFLECTOR_COUNTRY_CODE}."
                 else
                     info "Using worldwide mirrors (might be slower)."
                 fi
            fi
         else
            warn "Could not detect a valid country code automatically."
            prompt "Enter desired 2-letter country code (e.g., US, CA, DE) or leave blank for worldwide: " MANUAL_COUNTRY_CODE
            if [[ -n "$MANUAL_COUNTRY_CODE" ]]; then
                REFLECTOR_COUNTRY_CODE="$MANUAL_COUNTRY_CODE"
                info "Using manually entered country code: ${REFLECTOR_COUNTRY_CODE}."
            else
                info "Using worldwide mirrors (might be slower)."
            fi
         fi
    else
        warn "Could not reach ipinfo.io to detect country."
        prompt "Enter desired 2-letter country code (e.g., US, CA, DE) or leave blank for worldwide: " MANUAL_COUNTRY_CODE
        if [[ -n "$MANUAL_COUNTRY_CODE" ]]; then
            REFLECTOR_COUNTRY_CODE="$MANUAL_COUNTRY_CODE"
            info "Using manually entered country code: ${REFLECTOR_COUNTRY_CODE}."
        else
            info "Using worldwide mirrors (might be slower)."
        fi
    fi


    REFLECTOR_ARGS=("--protocol" "https" "--latest" "20" "--sort" "rate")
    if [[ -n "$REFLECTOR_COUNTRY_CODE" ]]; then
         REFLECTOR_ARGS+=("--country" "${REFLECTOR_COUNTRY_CODE}")
    fi

    # Run reflector
    info "Running reflector with args: ${REFLECTOR_ARGS[*]}"
    reflector "${REFLECTOR_ARGS[@]}" --save /etc/pacman.d/mirrorlist
    check_status "Running reflector"
    success "Mirrorlist updated."

    # Enable parallel downloads & Color
    if confirm "Enable parallel downloads in pacman? (Recommended)"; then
        while true; do
            prompt "How many parallel downloads? (1-10, default: ${DEFAULT_PARALLEL_DL}): " PARALLEL_DL_COUNT_INPUT
            PARALLEL_DL_COUNT_INPUT=${PARALLEL_DL_COUNT_INPUT:-$DEFAULT_PARALLEL_DL}
            if [[ "$PARALLEL_DL_COUNT_INPUT" =~ ^[1-9]$|^10$ ]]; then
                PARALLEL_DL_COUNT=$PARALLEL_DL_COUNT_INPUT # Store validated count
                info "Setting parallel downloads to ${PARALLEL_DL_COUNT}."
                # Use more robust sed for ParallelDownloads
                # Uncomment if commented
                sed -i -E "s/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                # Add if not present (append to [options] section or end of file)
                if ! grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
                    # Try adding under [options]
                    if grep -q "\[options\]" /etc/pacman.conf; then
                         sed -i "/\[options\]/a ParallelDownloads = ${PARALLEL_DL_COUNT}" /etc/pacman.conf
                    else # Append if [options] not found (unlikely)
                        echo "ParallelDownloads = ${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
                    fi
                else # Modify if already present but maybe wrong value
                    sed -i -E "s/^[[:space:]]*(ParallelDownloads).*/\1 = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                fi
                break
            else
                error "Please enter a number between 1 and 10."
            fi
        done
        # Use more robust sed for Color (uncomment or add)
        if grep -q -E "^#[[:space:]]*Color" /etc/pacman.conf; then
            sed -i -E "s/^[[:space:]]*#[[:space:]]*Color.*/Color/" /etc/pacman.conf
        elif ! grep -q -E "^[[:space:]]*Color" /etc/pacman.conf; then
             if grep -q "\[options\]" /etc/pacman.conf; then
                 sed -i "/\[options\]/a Color" /etc/pacman.conf
             else
                 echo "Color" >> /etc/pacman.conf
             fi
        fi
        success "Pacman ParallelDownloads and Color configured."
    else
        info "Parallel downloads disabled. Color might still be enabled if it was already."
        sed -i -E 's/^[[:space:]]*ParallelDownloads/#ParallelDownloads/' /etc/pacman.conf
    fi

    # Enable Multilib if Steam is selected (for the live env pacstrap)
    if $INSTALL_STEAM; then
        info "Ensuring Multilib repository is enabled in live environment for pacstrap..."
        # Make sed idempotent: only uncomment if commented
        # Finds [multilib] header, goes to next line (n), substitutes #Include with Include
        sed -i '/\[multilib\]/{N;s/\n#Include/\nInclude/}' /etc/pacman.conf
        # Handle case where Include is missing entirely (add it)
        if grep -q '\[multilib\]' /etc/pacman.conf && ! grep -A1 '\[multilib\]' /etc/pacman.conf | grep -q 'Include'; then
            sed -i '/\[multilib\]/a Include = /etc/pacman.d/mirrorlist-multilib' /etc/pacman.conf
        fi
        check_status "Enabling multilib repo in live env pacman.conf"
        success "Multilib repository enabled for live environment."
    else
        info "Multilib repository remains disabled in live environment."
    fi

    # Refresh package databases with new mirrors and settings
    info "Synchronizing package databases..."
    pacman -Syy
    check_status "pacman -Syy"
}


partition_and_format() {
    info "Partitioning ${TARGET_DISK} for ${BOOT_MODE}..."

    # Partitioning using parted (more robust commands)
    PARTED_CMD_BASE=(parted -s "${TARGET_DISK}" --)

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Creating GPT partition table for UEFI on ${TARGET_DISK}..."
        "${PARTED_CMD_BASE[@]}" mklabel gpt
        check_status "Creating GPT label on ${TARGET_DISK}"
        # Partition 1: EFI System Partition (ESP)
        "${PARTED_CMD_BASE[@]}" mkpart ESP fat32 1MiB "${BOOT_PART_SIZE}"
        check_status "Creating EFI partition on ${TARGET_DISK}"
        "${PARTED_CMD_BASE[@]}" set 1 esp on
        check_status "Setting ESP flag on partition 1"
        BOOT_PARTITION="${PART_PREFIX}1"
        local current_end="${BOOT_PART_SIZE}" # Track end of last partition

        # Partition 2: Swap (optional)
        if [[ -n "$SWAP_PART_SIZE" ]]; then
            "${PARTED_CMD_BASE[@]}" mkpart primary linux-swap "${current_end}" "-${SWAP_PART_SIZE}"
            check_status "Creating Swap partition on ${TARGET_DISK}"
            SWAP_PARTITION="${PART_PREFIX}2"
            # The end point for root is now the start of swap (-$SWAP_PART_SIZE used above covers this)
             current_end="-$SWAP_PART_SIZE" # Special syntax for "size from end"
        else
            SWAP_PARTITION=""
            # Root starts immediately after boot
        fi

        # Partition 3 (or 2): Root filesystem (takes remaining space)
        "${PARTED_CMD_BASE[@]}" mkpart primary ext4 "${current_end}" 100%
        check_status "Creating Root partition on ${TARGET_DISK}"
        ROOT_PARTITION="${PART_PREFIX}$([[ -n "$SWAP_PARTITION" ]] && echo 3 || echo 2)" # Assign correct number

    else # BIOS
        info "Creating MBR partition table for BIOS on ${TARGET_DISK}..."
        # Ensure GPT is gone if switching from UEFI attempt
        sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true
        "${PARTED_CMD_BASE[@]}" mklabel msdos
        check_status "Creating MBR label on ${TARGET_DISK}"
        # Partition 1: Boot partition (ext4 for BIOS boot, can hold GRUB stages)
        "${PARTED_CMD_BASE[@]}" mkpart primary ext4 1MiB "${BOOT_PART_SIZE}"
        check_status "Creating Boot partition on ${TARGET_DISK}"
        "${PARTED_CMD_BASE[@]}" set 1 boot on
        check_status "Setting boot flag on partition 1"
        BOOT_PARTITION="${PART_PREFIX}1"
        local current_end="${BOOT_PART_SIZE}"

        # Partition 2: Swap (optional)
        if [[ -n "$SWAP_PART_SIZE" ]]; then
             # Start after boot, end leaving swap size at the end
            "${PARTED_CMD_BASE[@]}" mkpart primary linux-swap "${current_end}" "-${SWAP_PART_SIZE}"
            check_status "Creating Swap partition on ${TARGET_DISK}"
            SWAP_PARTITION="${PART_PREFIX}2"
            current_end="-$SWAP_PART_SIZE"
        else
            SWAP_PARTITION=""
        fi

        # Partition 3 (or 2): Root filesystem
        "${PARTED_CMD_BASE[@]}" mkpart primary ext4 "${current_end}" 100%
        check_status "Creating Root partition on ${TARGET_DISK}"
        ROOT_PARTITION="${PART_PREFIX}$([[ -n "$SWAP_PARTITION" ]] && echo 3 || echo 2)"
    fi

    # Reread partition table to ensure kernel sees changes
    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 2 # Give kernel another moment

    info "Disk layout planned:"
    info " Boot: ${BOOT_PARTITION}"
    [[ -n "$SWAP_PARTITION" ]] && info " Swap: ${SWAP_PARTITION}"
    info " Root: ${ROOT_PARTITION}"
    lsblk "${TARGET_DISK}" # Show the result
    confirm "Proceed with formatting?" || { error "Formatting cancelled."; exit 1; }


    # --- Formatting ---
    info "Formatting partitions..."
    # Use partition variables directly, as they contain the full /dev/... path
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkfs.fat -F32 "${BOOT_PARTITION}"
        check_status "Formatting EFI partition ${BOOT_PARTITION}"
    else # BIOS/MBR
        mkfs.ext4 -F "${BOOT_PARTITION}" # Using Ext4 for /boot in BIOS mode
        check_status "Formatting Boot partition ${BOOT_PARTITION}"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        mkswap "${SWAP_PARTITION}"
        check_status "Formatting Swap partition ${SWAP_PARTITION}"
    fi

    mkfs.ext4 -F "${ROOT_PARTITION}"
    check_status "Formatting Root partition ${ROOT_PARTITION}"

    success "Partitions formatted."
}

mount_filesystems() {
    info "Mounting filesystems..."
    # Use partition variables directly
    mount "${ROOT_PARTITION}" /mnt
    check_status "Mounting root partition ${ROOT_PARTITION} to /mnt"

    # Mount boot partition under /mnt/boot
    # mount --mkdir handles creating /mnt/boot if needed
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot
    check_status "Mounting boot partition ${BOOT_PARTITION} to /mnt/boot"

    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "${SWAP_PARTITION}"
        check_status "Activating swap partition ${SWAP_PARTITION}"
    fi
    success "Filesystems mounted."
    # Verify mounts
    findmnt /mnt
    findmnt /mnt/boot
    [[ -n "$SWAP_PARTITION" ]] && swapon --show
}

install_base_system() {
    info "Installing base system packages (pacstrap)... This might take a while."

    # Determine CPU vendor for microcode
    CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    MICROCODE_PACKAGE=""
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        MICROCODE_PACKAGE="intel-ucode"
    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        MICROCODE_PACKAGE="amd-ucode"
    fi
    [[ -n "$MICROCODE_PACKAGE" ]] && info "Detected ${CPU_VENDOR}, adding ${MICROCODE_PACKAGE}."

    # Base packages
    local base_pkgs=(
        "base" "$SELECTED_KERNEL" "linux-firmware" "base-devel" "grub"
        "networkmanager" "nano" "git" "wget" "curl" "reflector" "zsh"
        "btop" "fastfetch" "man-db" "man-pages" "texinfo" # Add man pages support
        "openssh" # Include SSH server by default
        "pipewire" "pipewire-pulse" "pipewire-alsa" "wireplumber" "gst-plugin-pipewire" # Modern audio stack
        "power-profiles-daemon" # For power management on laptops/desktops
    )
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        base_pkgs+=("efibootmgr")
    fi
    [[ -n "$MICROCODE_PACKAGE" ]] && base_pkgs+=("$MICROCODE_PACKAGE")

    # Desktop Environment packages
    local de_pkgs=()
    ENABLE_DM="" # Reset DM variable
    case $SELECTED_DE_INDEX in
        0) # Server
            info "No GUI packages selected (Server install)."
            # openssh already in base_pkgs
            ;;
        1) # KDE Plasma
            de_pkgs+=( "plasma-desktop" "sddm" "konsole" "dolphin" "gwenview" "ark" "kcalc" "spectacle" "kate" "kscreen" "flatpak" "discover" "partitionmanager" "p7zip" "firefox" "plasma-nm" )
            ENABLE_DM="sddm"
            ;;
        2) # GNOME
             # Added gnome-tweaks, extensions, remove gnome-software (use Discover/Flatpak), add gearlever for AppImage
            de_pkgs+=( "gnome-shell" "gdm" "gnome-terminal" "nautilus" "gnome-text-editor" "gnome-control-center" "gnome-backgrounds" "eog" "file-roller" "flatpak" "firefox" "gnome-shell-extensions" "gnome-tweaks" "xdg-desktop-portal-gnome" )
            ENABLE_DM="gdm"
            ;;
        3) # XFCE
             # Added goodies, file-roller, use lightdm-gtk-greeter
            de_pkgs+=( "xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter" "xfce4-terminal" "thunar" "mousepad" "ristretto" "file-roller" "flatpak" "firefox" "network-manager-applet" )
            ENABLE_DM="lightdm"
            ;;
        4) # LXQt
            de_pkgs+=( "lxqt" "sddm" "qterminal" "pcmanfm-qt" "featherpad" "lximage-qt" "ark" "flatpak" "firefox" "network-manager-applet" )
            ENABLE_DM="sddm"
            ;;
        5) # MATE
            de_pkgs+=( "mate" "mate-extra" "lightdm" "lightdm-gtk-greeter" "mate-terminal" "caja" "pluma" "eom" "engrampa" "flatpak" "firefox" "network-manager-applet" )
            ENABLE_DM="lightdm"
            ;;
    esac

    # Optional packages
    local optional_pkgs=()
    $INSTALL_STEAM && optional_pkgs+=("steam")
    $INSTALL_DISCORD && optional_pkgs+=("discord")
    # Add other optional packages here
    # $INSTALL_LIBREOFFICE && optional_pkgs+=("libreoffice-fresh")

    # Add fonts for Oh My Zsh 'agnoster' theme if selected later
    # Check if OMZ will be installed (prompt happens later, but we know default shell is Zsh)
    # Assuming user *might* install OMZ if Zsh is default shell
    # Better: Install font if OMZ *is* installed. Do this in `install_oh_my_zsh` or `configure_installed_system`.
    # Let's add it conditionally later inside chroot if OMZ was installed.

    # Combine all package lists
    local all_pkgs=("${base_pkgs[@]}" "${de_pkgs[@]}" "${optional_pkgs[@]}")

    info "Packages to install: ${all_pkgs[*]}"
    confirm "Proceed with package installation?" || { error "Installation aborted."; exit 1; }

    # Run pacstrap
    pacstrap -K /mnt "${all_pkgs[@]}"
    check_status "Running pacstrap"

    success "Base system and selected packages installed."
}

configure_installed_system() {
    info "Configuring the installed system (chroot)..."

    # Generate fstab
    info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab
    check_status "Generating fstab"
    # Validate fstab entries are using UUIDs (or LABELs) not /dev/sdX
    if grep -qE ' / .* ext4' /mnt/etc/fstab && ! grep -qE '^UUID=' /mnt/etc/fstab | grep -qE ' / .* ext4'; then
        warn "/etc/fstab root entry might not be using UUID. Manual check recommended: /mnt/etc/fstab"
    fi
    if grep -qE ' /boot ' /mnt/etc/fstab && ! grep -qE '^(UUID=|LABEL=)' /mnt/etc/fstab | grep -qE ' /boot '; then
        warn "/etc/fstab boot entry might not be using UUID/LABEL. Manual check recommended: /mnt/etc/fstab"
    fi
    success "fstab generated (/mnt/etc/fstab)."


    # Copy necessary config files into chroot environment
    info "Copying Pacman configuration to chroot environment..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    check_status "Copying mirrorlist to /mnt"
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    check_status "Copying pacman.conf to /mnt"


    # Create chroot configuration script using Heredoc
    # Pass all required variables; ensure proper quoting inside heredoc if needed
    cat <<CHROOT_SCRIPT_EOF > /mnt/configure_chroot.sh
#!/bin/bash
set -e # Exit on error
set -o pipefail # Exit on pipe failures

# --- Variables Passed from Main Script ---
# These are already expanded by the outer shell before the heredoc is written
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}" # Note: Storing passwords in script is insecure, but common for automation.
ROOT_PASSWORD="${ROOT_PASSWORD}"
ENABLE_DM="${ENABLE_DM}"
INSTALL_STEAM=${INSTALL_STEAM} # Boolean (true/false)
SELECTED_TIMEZONE="${SELECTED_TIMEZONE}"
SELECTED_LOCALE="${SELECTED_LOCALE}"
LANG_SETTING="${LANG_SETTING}" # e.g., en_US
KEYMAP="${KEYMAP}" # Console keymap
X11_KEYMAP="${X11_KEYMAP}" # X11 keymap
INSTALL_DESKTOP_ENV=${INSTALL_DESKTOP_ENV} # Boolean if DE was installed
PARALLEL_DL_COUNT="${PARALLEL_DL_COUNT:-0}" # Default to 0 if not set earlier
INSTALL_OMZ_FLAG_FILE="/tmp/install_omz_done" # Flag file to signal OMZ installation

# --- Chroot Logging functions ---
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "\${C_BLUE}\${C_BOLD}[CHROOT INFO]\${C_OFF} \$1"; }
error() { echo -e "\${C_RED}\${C_BOLD}[CHROOT ERROR]\${C_OFF} \$1"; exit 1; } # Exit on error in chroot
success() { echo -e "\${C_GREEN}\${C_BOLD}[CHROOT SUCCESS]\${C_OFF} \$1"; }
warn() { echo -e "\${C_YELLOW}\${C_BOLD}[CHROOT WARN]\${C_OFF} \$1"; }
check_status_chroot() {
    local status=\$?
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; fi
    return \$status
}

# --- Chroot Configuration Steps ---

info "Setting timezone (\${SELECTED_TIMEZONE})..."
ln -sf "/usr/share/zoneinfo/\${SELECTED_TIMEZONE}" /etc/localtime
check_status_chroot "Linking timezone"
hwclock --systohc # Set hardware clock from system time (UTC recommended)
check_status_chroot "Setting hardware clock (hwclock --systohc)"
success "Timezone set."

info "Configuring Locale (\${SELECTED_LOCALE})..."
# Uncomment the selected locale in /etc/locale.gen
sed -i "s/^#\?[[:space:]]*\(${SELECTED_LOCALE}\)/\1/" /etc/locale.gen
check_status_chroot "Uncommenting locale \${SELECTED_LOCALE} in locale.gen"
# Regenerate locales
locale-gen
check_status_chroot "Generating locales (locale-gen)"
# Set system language
echo "LANG=\${LANG_SETTING}.UTF-8" > /etc/locale.conf
check_status_chroot "Setting LANG in /etc/locale.conf"
success "Locale configured."

info "Configuring Keyboard Layout..."
# Set console keymap persistently
echo "KEYMAP=\${KEYMAP}" > /etc/vconsole.conf
check_status_chroot "Setting KEYMAP in /etc/vconsole.conf"
success "Console keymap set."
# Set X11 keyboard layout if a DE was installed
if [[ "\${INSTALL_DESKTOP_ENV}" == "true" ]]; then
    info "Setting X11 keyboard layout (\${X11_KEYMAP})..."
    # Create Xorg config directory if it doesn't exist
    mkdir -p /etc/X11/xorg.conf.d
    # Create keyboard config file
    cat <<EOF_XKB > /etc/X11/xorg.conf.d/00-keyboard.conf
Section "InputClass"
    Identifier "system-keyboard"
    MatchIsKeyboard "on"
    Option "XkbLayout" "\${X11_KEYMAP}"
    # Add options like Variant and Options if needed, e.g.:
    # Option "XkbVariant" ""
    # Option "XkbOptions" "grp:alt_shift_toggle"
EndSection
EOF_XKB
    check_status_chroot "Creating X11 keyboard config /etc/X11/xorg.conf.d/00-keyboard.conf"
    success "X11 keyboard layout configured."
else
    info "Skipping X11 keyboard layout configuration (no desktop environment)."
fi

info "Setting hostname (\${HOSTNAME})..."
echo "\${HOSTNAME}" > /etc/hostname
# Create basic /etc/hosts file
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1    localhost
::1          localhost
127.0.1.1    \${HOSTNAME}.localdomain    \${HOSTNAME}
EOF_HOSTS
check_status_chroot "Writing /etc/hosts"
success "Hostname set."

info "Setting root password..."
# Use chpasswd for robustness
echo "root:\${ROOT_PASSWORD}" | chpasswd
check_status_chroot "Setting root password via chpasswd"
success "Root password set."

info "Creating user \${USERNAME}..."
# Create user, add to wheel group, set default shell to Zsh (as it's installed)
useradd -m -g users -G wheel -s /bin/zsh "\${USERNAME}"
check_status_chroot "Creating user \${USERNAME} with useradd"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd
check_status_chroot "Setting password for \${USERNAME} via chpasswd"
success "User \${USERNAME} created and password set. Default shell: /bin/zsh."

info "Configuring sudo for wheel group..."
# Use visudo is safer, but sed is common in scripts. Ensure the line is exactly matched.
# This regex allows for potential ":ALL" part for NOPASSWD scenarios if manually added later.
SUDOERS_LINE='%wheel ALL=(ALL:ALL) ALL'
if grep -q -E "^#[[:space:]]*${SUDOERS_LINE}" /etc/sudoers; then
    sed -i -E "s/^#[[:space:]]*(${SUDOERS_LINE})/\1/" /etc/sudoers
    check_status_chroot "Uncommenting wheel group in sudoers"
    success "Sudo configured for wheel group."
elif grep -q -E "^[[:space:]]*${SUDOERS_LINE}" /etc/sudoers; then
    warn "Wheel group already uncommented in sudoers."
else
    warn "Could not find standard wheel group line ('${SUDOERS_LINE}') in /etc/sudoers to uncomment. Adding it."
    # Add the line if it's missing entirely
    echo "${SUDOERS_LINE}" >> /etc/sudoers
fi

info "Ensuring Pacman config inside chroot (ParallelDownloads, Color)..."
# Ensure ParallelDownloads is set
if [[ "\${PARALLEL_DL_COUNT}" -gt 0 ]]; then
    # Use robust sed logic copied from configure_mirrors
    sed -i -E "s/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = \${PARALLEL_DL_COUNT}/" /etc/pacman.conf
    if ! grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
        if grep -q "\[options\]" /etc/pacman.conf; then
             sed -i "/\[options\]/a ParallelDownloads = \${PARALLEL_DL_COUNT}" /etc/pacman.conf
        else
            echo "ParallelDownloads = \${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
        fi
    else
        sed -i -E "s/^[[:space:]]*(ParallelDownloads).*/\1 = \${PARALLEL_DL_COUNT}/" /etc/pacman.conf
    fi
    info "ParallelDownloads set to \${PARALLEL_DL_COUNT}."
else
    info "ParallelDownloads disabled or not set."
fi
# Ensure Color is set
if grep -q -E "^#[[:space:]]*Color" /etc/pacman.conf; then
    sed -i -E "s/^[[:space:]]*#[[:space:]]*Color.*/Color/" /etc/pacman.conf
    info "Color enabled."
elif ! grep -q -E "^[[:space:]]*Color" /etc/pacman.conf; then
     if grep -q "\[options\]" /etc/pacman.conf; then
         sed -i "/\[options\]/a Color" /etc/pacman.conf
     else
         echo "Color" >> /etc/pacman.conf
     fi
     info "Color enabled."
fi

# Ensure Multilib is enabled inside chroot if Steam was selected
if [[ "\${INSTALL_STEAM}" == "true" ]]; then
    info "Ensuring Multilib repository is enabled inside chroot..."
    # Same robust logic as before
    sed -i '/\[multilib\]/{N;s/\n#Include/\nInclude/}' /etc/pacman.conf
    if grep -q '\[multilib\]' /etc/pacman.conf && ! grep -A1 '\[multilib\]' /etc/pacman.conf | grep -q 'Include'; then
        sed -i '/\[multilib\]/a Include = /etc/pacman.d/mirrorlist-multilib' /etc/pacman.conf
    fi
    check_status_chroot "Enabling multilib repo in chroot pacman.conf"
    success "Multilib repository ensured in chroot."
    # Synchronize DBs after enabling multilib, needed before installing multilib packages
    info "Synchronizing package databases after enabling multilib..."
    pacman -Syy
    check_status_chroot "pacman -Syy after multilib enable"
fi

# Install nerd-fonts if Oh My Zsh was installed (check flag file later)
# We need to run this AFTER the OMZ install step finishes outside chroot
# The install_oh_my_zsh function will touch the flag file if successful

info "Enabling Essential System Services..."
systemctl enable NetworkManager.service
check_status_chroot "Enabling NetworkManager service"
success "NetworkManager enabled."

# Enable display manager if one was installed
if [[ -n "\${ENABLE_DM}" ]]; then
    info "Enabling Display Manager service (\${ENABLE_DM})..."
    systemctl enable "\${ENABLE_DM}.service"
    check_status_chroot "Enabling \${ENABLE_DM} service"
    success "\${ENABLE_DM} enabled."
else
    info "No Display Manager to enable (Server install or manual setup)."
fi

# Enable SSHD service (openssh was installed as part of base)
info "Enabling SSH daemon (sshd)..."
systemctl enable sshd.service
check_status_chroot "Enabling sshd service"
success "sshd enabled."

# Enable time synchronization
info "Enabling systemd-timesyncd for time synchronization..."
systemctl enable systemd-timesyncd.service
check_status_chroot "Enabling systemd-timesyncd service"
success "systemd-timesyncd enabled."

# Enable power profiles daemon (installed with base)
info "Enabling power-profiles-daemon..."
systemctl enable power-profiles-daemon.service
check_status_chroot "Enabling power-profiles-daemon service"
success "power-profiles-daemon enabled."

# --- Final system update and cleanup ---
# Optional: Run a final system update inside chroot?
# info "Performing final system update (pacman -Syu)..."
# pacman -Syu --noconfirm
# check_status_chroot "Final system update (pacman -Syu)"

info "Updating initial ramdisk environment (mkinitcpio)..."
# This is crucial after kernel/driver/config changes
mkinitcpio -P # Regenerate all presets
check_status_chroot "Running mkinitcpio -P"
success "Initramfs updated."

# Check if Oh My Zsh was installed successfully (flag file exists)
if [[ -f "\${INSTALL_OMZ_FLAG_FILE}" ]]; then
    info "Oh My Zsh was installed, attempting to install nerd-fonts..."
    # Try installing nerd-fonts (provides powerline symbols etc)
    pacman -S --noconfirm --needed ttf-nerd-fonts-symbols-common
    if check_status_chroot "Installing nerd-fonts for OMZ themes"; then
        success "Installed ttf-nerd-fonts-symbols-common for OMZ themes."
    else
        warn "Could not install nerd-fonts automatically. You may need to install manually for some OMZ themes."
    fi
    # Clean up flag file
    rm -f "\${INSTALL_OMZ_FLAG_FILE}"
fi


success "Chroot configuration script finished."

CHROOT_SCRIPT_EOF

    chmod +x /mnt/configure_chroot.sh
    check_status "Setting execute permissions on chroot script"

    info "Executing configuration script inside chroot..."
    arch-chroot /mnt /configure_chroot.sh
    check_status "Executing chroot configuration script"

    # Clean up the script
    rm /mnt/configure_chroot.sh

    success "System configuration inside chroot complete."
}


install_bootloader() {
    info "Installing and configuring GRUB bootloader for ${BOOT_MODE}..."

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Running grub-install for UEFI..."
        # Ensure /boot is mounted before running this
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
        check_status "Running grub-install for UEFI"
    else # BIOS
        info "Running grub-install for BIOS on ${TARGET_DISK}..."
        # TARGET_DISK already contains /dev/..., so use it directly
        arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"
        check_status "Running grub-install for BIOS on ${TARGET_DISK}"
    fi

    info "Generating GRUB configuration file (/boot/grub/grub.cfg)..."
    # Check if os-prober should be enabled (useful for dual-booting)
    if confirm "Enable os-prober to detect other operating systems? (Requires 'os-prober' package)"; then
         info "Ensuring os-prober package is installed..."
         arch-chroot /mnt pacman -S --noconfirm --needed os-prober
         check_status "Installing os-prober"
         info "Enabling os-prober in GRUB configuration..."
         # Uncomment the GRUB_DISABLE_OS_PROBER=false line in /etc/default/grub
         arch-chroot /mnt sed -i -E 's/^[# ]*GRUB_DISABLE_OS_PROBER=.*/GRUB_DISABLE_OS_PROBER=false/' /etc/default/grub
         check_status "Editing /etc/default/grub for os-prober"
         success "os-prober enabled."
    else
         info "os-prober will not be enabled."
    fi

    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    check_status "Running grub-mkconfig"

    success "GRUB bootloader installed and configured."
}

install_oh_my_zsh() {
    # Use Zsh as default shell was set in chroot script if installed
    if confirm "Install Oh My Zsh for user '${USERNAME}' and root? (Internet required)"; then
        info "Installing Oh My Zsh..."
        local user_home="/home/${USERNAME}"
        local install_script_url="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
        local omz_install_cmd # Command to run inside chroot
        local omz_flag_file="/mnt/tmp/install_omz_done" # Flag file path

        # Create tmp dir if it doesn't exist
        mkdir -p /mnt/tmp

        # Try curl first, then wget for the install script
        omz_install_cmd=$(cat <<EOF
sh -c "\$(curl -fsSL ${install_script_url}) || \$(wget -qO- ${install_script_url})" "" --unattended
EOF
)

        # Install for root user
        info "Installing Oh My Zsh for root..."
        # Run within sh -c to handle the command substitution properly inside chroot
        if arch-chroot /mnt sh -c "export RUNZSH=no CHSH=no; ${omz_install_cmd}"; then
            success "Oh My Zsh installed for root."
            # Set a reasonable default theme for root
            arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
            check_status "Setting OMZ theme for root"
        else
            error "Failed to download and run Oh My Zsh install script for root."
            # Decide if we should continue for the user or abort? Let's abort.
            return 1 # Signal failure
        fi

        # Install for the regular user
        info "Installing Oh My Zsh for user ${USERNAME}..."
        # Run as the user, setting HOME environment variable is important
        if arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "${omz_install_cmd}"; then
            success "Oh My Zsh installed for ${USERNAME}."
            # Set user theme (e.g., agnoster, requires powerline/nerd fonts)
            arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"
            check_status "Setting OMZ theme for ${USERNAME}"
            warn "User ${USERNAME}'s theme set to 'agnoster'. Nerd Fonts will be installed if possible."
            # Touch the flag file to signal successful OMZ installation for font install later
            touch "${omz_flag_file}"
            check_status "Creating OMZ success flag file"
        else
             error "Failed to download and run Oh My Zsh install script for ${USERNAME}."
             # If root succeeded but user failed, maybe just warn? Let's error for consistency.
             return 1 # Signal failure
        fi
    else
        info "Oh My Zsh will not be installed."
        info "Setting user ${USERNAME}'s shell back to /bin/bash (if Zsh was default)."
        # Check current shell first? Assumed Zsh was set as default earlier.
        if arch-chroot /mnt grep -q "^${USERNAME}:.*:/bin/zsh$" /etc/passwd; then
             arch-chroot /mnt chsh -s /bin/bash "${USERNAME}"
             check_status "Setting ${USERNAME}'s shell to bash"
             success "User ${USERNAME}'s shell set to /bin/bash."
        else
             info "User ${USERNAME}'s shell is not /bin/zsh, no change needed."
        fi
        # Set root shell back to bash as well? Usually fine to leave root as Zsh if installed.
        # arch-chroot /mnt chsh -s /bin/bash root
    fi
}


final_steps() {
    success "Arch Linux installation script finished!"
    info "System configuration is complete based on your selections."
    info "--- Recommendations ---"
    info "1. Review the installed system using 'arch-chroot /mnt'."
    info "   - Check '/etc/fstab' for correct UUIDs/mount points."
    info "   - Verify users with 'cat /etc/passwd'."
    info "   - List enabled services with 'arch-chroot /mnt systemctl list-unit-files --state=enabled'."
    info "2. Check '/var/log/pacman.log' inside the chroot for any installation warnings."
    warn "3. REMOVE the installation medium (USB/CD/ISO) before rebooting."

    # Attempt final unmount (best effort)
    info "Attempting final unmount of filesystems..."
    sync # Sync filesystem buffers before unmounting
    # Try recursive unmount, force if busy (lazy unmount) as a last resort
    umount -R /mnt &>/dev/null || umount -R -l /mnt &>/dev/null || warn "Could not fully unmount /mnt. Check 'findmnt /mnt'."
    # Use parameter expansion check for swap variable
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then
        swapoff "${SWAP_PARTITION}" &>/dev/null || warn "Could not disable swap ${SWAP_PARTITION}."
    fi
    success "Attempted unmount and swapoff."

    echo -e "${C_GREEN}${C_BOLD}"
    echo "----------------------------------------------------"
    echo " Installation finished at $(date)."
    echo " You can now type 'reboot' or 'shutdown now'."
    echo "----------------------------------------------------"
    echo -e "${C_OFF}"
}

# --- Run the main function ---
main

exit 0 # Explicitly exit with success code if main finishes
