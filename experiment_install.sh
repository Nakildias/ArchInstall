#!/bin/bash

# Arch Linux Installation Script - Rewritten
# Version: 2.2 (Based on user-provided script)

# --- Configuration ---
SCRIPT_VERSION="2.2"
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
DEFAULT_REGION="America" # Default timezone region (Adjust as needed)
DEFAULT_CITY="Toronto"   # Default timezone city (Adjust as needed)

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
    error "--- SCRIPT INTERRUPTED OR FAILED ---"
    info "Performing cleanup..."
    # Attempt to unmount everything in reverse order in case of script failure
    # Use &>/dev/null to suppress errors if already unmounted
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    # Deactivate swap if it was activated and variable exists
    # Use parameter expansion to check if variable is set and not empty
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null
    info "Cleanup finished. If the script failed, some resources might still be mounted/active."
    info "Check with 'lsblk' and 'mount'."
    # Ensure cursor is visible and colors are reset on exit
    tput cnorm
    echo -e "${C_OFF}"
}

# --- Main Installation Logic ---

main() {
    # Initial setup
    setup_environment

    # Pre-installation checks
    check_boot_mode
    check_internet

    # User configuration gathering
    select_disk
    configure_partitioning       # Determines PART_PREFIX
    configure_hostname_user
    select_kernel
    select_desktop_environment
    select_optional_packages     # Sets INSTALL_STEAM and ENABLE_MULTILIB flags

    # Perform installation steps
    configure_mirrors            # Enables multilib based on INSTALL_STEAM or ENABLE_MULTILIB
    partition_and_format         # Uses correct partition paths
    mount_filesystems            # Uses correct partition paths
    install_base_system          # Installs packages including Steam if selected
    configure_installed_system   # Configures chroot, ensures multilib based on INSTALL_STEAM or ENABLE_MULTILIB
    install_bootloader           # Uses correct target disk
    install_oh_my_zsh            # Optional

    # Finalization
    final_steps
}

# --- Function Definitions ---

setup_environment() {
    # Exit immediately if a command exits with a non-zero status.
    set -e
    # Cause pipelines to return the exit status of the last command that failed.
    set -o pipefail
    # Treat unset variables as an error when substituting (use with caution).
    # set -u

    info "Starting Arch Linux Installation Script v${SCRIPT_VERSION}"
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
        warn "Legacy BIOS mode detected. Installation will use MBR/BIOS boot."
    fi
    confirm "Proceed with ${BOOT_MODE} installation?" || { info "User cancelled."; exit 0; }
}

check_internet() {
    info "Checking internet connectivity..."
    # Use timeout to prevent long hangs
    if timeout 5 ping -c 1 archlinux.org &> /dev/null; then
        success "Internet connection available."
    else
        error "No internet connection detected. Please connect to the internet and restart the script."
        exit 1
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

    # Wipe existing signatures and partition table
    info "Wiping existing signatures and partition table on ${TARGET_DISK}..."
    sync # Ensure data is written before wiping
    # Attempt sgdisk first, then wipefs as fallback. Ignore errors if disk is clean.
    sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true
    sync # Ensure wipe completes
    check_status "Wiping disk ${TARGET_DISK}"
    # Reread partition table
    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 2 # Give kernel a moment to recognize changes
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
        prompt "Enter Swap size (e.g., 4G, 8G, leave blank for NO swap): " SWAP_SIZE_INPUT
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
    while true; do
        prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
        # Basic validation: not empty, no spaces/quotes
        [[ -n "$HOSTNAME" && ! "$HOSTNAME" =~ [[:space:]\'\"] ]] && break || error "Hostname cannot be empty and should not contain spaces or quotes."
    done

    while true; do
        prompt "Enter username for the primary user: " USERNAME
        # Basic validation: not empty, no spaces/quotes
        if [[ -n "$USERNAME" && ! "$USERNAME" =~ [[:space:]\'\"] ]]; then
            info "Username set to: ${USERNAME}"
            break
        else
            error "Username cannot be empty and should not contain spaces or quotes."
        fi
    done

    # --- Password Input (Uses read -s for security) ---
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
            # Store index to determine package list later
            SELECTED_DE_INDEX=$((REPLY - 1))
            info "Selected environment: ${C_BOLD}${SELECTED_DE_NAME}${C_OFF}"
            break
        else
            error "Invalid selection."
        fi
    done
}

select_optional_packages() {
    info "Optional Packages Selection..."
    INSTALL_STEAM=false
    INSTALL_DISCORD=false
    ENABLE_MULTILIB=false # Default for the new option

    # Check for Steam installation
    if confirm "Install Steam? (Requires enabling the multilib repository)"; then
        INSTALL_STEAM=true
        info "Steam will be installed. Multilib repository will be enabled."
    else
        info "Steam will not be installed."
    fi

    # Check for Discord installation
    if confirm "Install Discord?"; then
        INSTALL_DISCORD=true
        info "Discord will be installed."
    else
        info "Discord will not be installed."
    fi

    # Check for explicitly enabling multilib (even if Steam isn't chosen)
    if confirm "Enable the multilib repository? (Needed for 32-bit software, automatically enabled if Steam is chosen)"; then
        ENABLE_MULTILIB=true
        info "User chose to enable the multilib repository."
    else
        # Only mention disabling if Steam wasn't selected either
        if [ "$INSTALL_STEAM" = "false" ]; then
             info "User chose not to explicitly enable the multilib repository (and Steam wasn't selected)."
        fi
    fi
}

configure_mirrors() {
    info "Configuring Pacman mirrors for optimal download speed..."
    warn "This may take a few moments."

    # Backup original mirrorlist
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    check_status "Backing up mirrorlist"

    # Getting current country based on IP for reflector (requires curl)
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

    # Configure parallel downloads & Color in pacman.conf
    if confirm "Enable parallel downloads and color in pacman? (Recommended)"; then
        while true; do
            prompt "How many parallel downloads? (1-10, default: ${DEFAULT_PARALLEL_DL}): " PARALLEL_DL_COUNT
            PARALLEL_DL_COUNT=${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}
            if [[ "$PARALLEL_DL_COUNT" =~ ^[1-9]$|^10$ ]]; then
                info "Setting parallel downloads to ${PARALLEL_DL_COUNT} and enabling color."
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
                break
            else
                error "Please enter a number between 1 and 10."
            fi
        done
    else
        info "Parallel downloads and color will remain at defaults (likely disabled)."
        # Optionally comment them out if needed
        # sed -i -E 's/^(ParallelDownloads)/#\1/' /etc/pacman.conf
        # sed -i -E 's/^(Color)/#\1/' /etc/pacman.conf
    fi

    # === Enable Multilib repository IF Steam OR Enable Multilib was selected ===
    if [ "$INSTALL_STEAM" = "true" ] || [ "$ENABLE_MULTILIB" = "true" ]; then
        info "Enabling Multilib repository..."
        # Use sed to uncomment the two lines for [multilib]
        # This makes it idempotent (running it again won't hurt)
        sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
        # Alternative simpler sed if Include is always the line after [multilib]
        # sed -i '/^#\[multilib\]/{N;s/#\[multilib\]\n#Include/\[multilib\]\nInclude/}' /etc/pacman.conf
        # Safest sed, only uncomment Include if [multilib] is uncommented or commented
        # sed -i '/^[[:space:]]*\[multilib\]/{ n; s/^[[:space:]]*#Include/Include/ }' /etc/pacman.conf
        check_status "Enabling multilib repository in /etc/pacman.conf"
        success "Multilib repository enabled."
    else
        info "Multilib repository will remain disabled (Neither Steam nor the explicit option was selected)."
        # Optional: Ensure multilib is commented out if neither condition is true
        # sed -i '/\[multilib\]/{ N; s/^([[:space:]]*\[multilib\]\n[[:space:]]*Include)/#\1/ }' /etc/pacman.conf
    fi

    # Refresh package databases with new mirrors and settings
    info "Synchronizing package databases..."
    pacman -Syy
    check_status "pacman -Syy"
    # Update keyring so user doesn't get corrupted package errors
    echo "Updating archlinux-keyring..."
    pacman -Sy archlinux-keyring --noconfirm
}

partition_and_format() {
    info "Partitioning ${TARGET_DISK} for ${BOOT_MODE}..."

    # Partitioning using parted
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Creating GPT partition table for UEFI on ${TARGET_DISK}..."
        # UEFI Partitioning: ESP (fat32), Swap (optional), Root (ext4)
        parted -s "${TARGET_DISK}" -- \
            mklabel gpt \
            mkpart ESP fat32 1MiB "${BOOT_PART_SIZE}" \
            set 1 esp on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -${SWAP_PART_SIZE}" ) \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-${SWAP_PART_SIZE}" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning disk ${TARGET_DISK} with GPT for UEFI"
        # Assign partition numbers for UEFI/GPT using calculated PART_PREFIX
        BOOT_PARTITION="${PART_PREFIX}1"
        if [[ -n "$SWAP_PART_SIZE" ]]; then
            SWAP_PARTITION="${PART_PREFIX}2"
            ROOT_PARTITION="${PART_PREFIX}3"
        else
            SWAP_PARTITION=""
            ROOT_PARTITION="${PART_PREFIX}2"
        fi
    else # BIOS
        info "Creating MBR partition table for BIOS on ${TARGET_DISK}..."
        # Ensure any previous GPT is gone (parted mklabel msdos might not be enough)
        sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true
        # BIOS Partitioning: Boot (ext4, boot flag), Swap (optional), Root (ext4)
        parted -s "${TARGET_DISK}" -- \
            mklabel msdos \
            mkpart primary ext4 1MiB "${BOOT_PART_SIZE}" \
            set 1 boot on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -${SWAP_PART_SIZE}" ) \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-${SWAP_PART_SIZE}" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning disk ${TARGET_DISK} with MBR for BIOS"
        # Assign partition numbers for BIOS/MBR using calculated PART_PREFIX
        BOOT_PARTITION="${PART_PREFIX}1"
        if [[ -n "$SWAP_PART_SIZE" ]]; then
            SWAP_PARTITION="${PART_PREFIX}2"
            ROOT_PARTITION="${PART_PREFIX}3"
        else
            SWAP_PARTITION=""
            ROOT_PARTITION="${PART_PREFIX}2"
        fi
    fi

    # Reread partition table to ensure kernel sees changes
    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 2 # Give kernel another moment

    info "Disk layout planned:"
    info " Boot: ${BOOT_PARTITION}"
    [[ -n "$SWAP_PARTITION" ]] && info " Swap: ${SWAP_PARTITION}"
    info " Root: ${ROOT_PARTITION}"
    lsblk "${TARGET_DISK}" # Show the result
    confirm "Proceed with formatting these partitions?" || { error "Formatting cancelled."; exit 1; }

    # --- Formatting ---
    info "Formatting partitions..."
    # Use partition variables directly, as they contain the full /dev/... path
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkfs.fat -F32 "${BOOT_PARTITION}"
        check_status "Formatting EFI partition ${BOOT_PARTITION} as FAT32"
    else # BIOS/MBR - Format /boot as ext4
        mkfs.ext4 -F "${BOOT_PARTITION}" # Use -F to force if needed
        check_status "Formatting Boot partition ${BOOT_PARTITION} as ext4"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        mkswap "${SWAP_PARTITION}"
        check_status "Formatting Swap partition ${SWAP_PARTITION}"
    fi

    mkfs.ext4 -F "${ROOT_PARTITION}" # Use -F to force if needed
    check_status "Formatting Root partition ${ROOT_PARTITION} as ext4"

    success "Partitions formatted."
}

mount_filesystems() {
    info "Mounting filesystems..."
    # Use partition variables directly
    mount "${ROOT_PARTITION}" /mnt
    check_status "Mounting root partition ${ROOT_PARTITION} on /mnt"

    # Mount boot partition under /mnt/boot
    # mount --mkdir handles creating /mnt/boot if it doesn't exist
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot
    check_status "Mounting boot partition ${BOOT_PARTITION} on /mnt/boot"

    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "${SWAP_PARTITION}"
        check_status "Activating swap partition ${SWAP_PARTITION}"
        info "Swap activated on ${SWAP_PARTITION}."
    fi

    success "Filesystems mounted."
    # Verify mounts
    info "Current mounts:"
    findmnt /mnt
    if [[ -d /mnt/boot ]]; then findmnt /mnt/boot; fi
    if [[ -n "$SWAP_PARTITION" ]]; then swapon --show; fi
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
    [[ -n "$MICROCODE_PACKAGE" ]] && info "Detected ${CPU_VENDOR}, adding ${MICROCODE_PACKAGE} package."

    # Base packages list
    local base_pkgs=(
        "base" "$SELECTED_KERNEL" "linux-firmware" "base-devel" "grub"
        "networkmanager" "nano" "vim" "git" "wget" "curl" "reflector" "zsh"
        "btop" "fastfetch" "man-db" "man-pages" "texinfo" # Common utilities
    )
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        base_pkgs+=("efibootmgr")
    fi
    [[ -n "$MICROCODE_PACKAGE" ]] && base_pkgs+=("$MICROCODE_PACKAGE")

    # Desktop Environment packages
    local de_pkgs=()
    ENABLE_DM="" # Will store the display manager service name
    case $SELECTED_DE_INDEX in
        0) # Server
            info "Selecting packages for Server (No GUI)."
            de_pkgs+=("openssh") # Common for servers
            ;;
        1) # KDE Plasma
            info "Selecting packages for KDE Plasma."
            de_pkgs+=( "plasma-desktop" "sddm" "konsole" "dolphin" "ark" "spectacle" "kate" "flatpak" "discover" "firefox" "plasma-nm" "gwenview" "kcalc" "kscreen" "partitionmanager" "p7zip" )
            ENABLE_DM="sddm"
            ;;
        2) # GNOME
            info "Selecting packages for GNOME."
            de_pkgs+=( "gnome" "gdm" "gnome-terminal" "nautilus" "gnome-text-editor" "gnome-control-center" "gnome-software" "eog" "file-roller" "flatpak" "firefox" "gnome-tweaks" )
            ENABLE_DM="gdm"
            ;;
        3) # XFCE
            info "Selecting packages for XFCE."
            de_pkgs+=( "xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter" "xfce4-terminal" "thunar" "mousepad" "ristretto" "file-roller" "flatpak" "firefox" "network-manager-applet" )
            ENABLE_DM="lightdm"
            ;;
        4) # LXQt
             info "Selecting packages for LXQt."
             de_pkgs+=( "lxqt" "sddm" "qterminal" "pcmanfm-qt" "featherpad" "lximage-qt" "ark" "flatpak" "firefox" "network-manager-applet" )
             ENABLE_DM="sddm"
             ;;
        5) # MATE
             info "Selecting packages for MATE."
             de_pkgs+=( "mate" "mate-extra" "lightdm" "lightdm-gtk-greeter" "mate-terminal" "caja" "pluma" "eom" "engrampa" "flatpak" "firefox" "network-manager-applet" )
             ENABLE_DM="lightdm"
             ;;
    esac

    # Optional packages based on user selection
    local optional_pkgs=()
    $INSTALL_STEAM && optional_pkgs+=("steam")
    $INSTALL_DISCORD && optional_pkgs+=("discord")

    # Combine all package lists
    local all_pkgs=("${base_pkgs[@]}" "${de_pkgs[@]}" "${optional_pkgs[@]}")

    info "Packages to be installed:"
    echo "${all_pkgs[*]}" | fold -s -w 80 # Print packages wrapped nicely
    confirm "Proceed with package installation using pacstrap?" || { error "Installation aborted by user."; exit 1; }

    # Run pacstrap (-K initializes keyring in chroot)
    pacstrap -K /mnt "${all_pkgs[@]}"
    check_status "Running pacstrap"

    success "Base system and selected packages installed successfully."
}

configure_installed_system() {
    info "Configuring the installed system (within chroot)..."

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
    # Copy DNS config if needed (NetworkManager usually handles this)
    # cp /etc/resolv.conf /mnt/etc/resolv.conf

    # Create chroot configuration script using Heredoc
    # This prevents issues with quoting and variable expansion inside chroot
    info "Creating chroot configuration script..."
    cat <<CHROOT_SCRIPT_EOF > /mnt/configure_chroot.sh
#!/bin/bash
# This script runs inside the chroot environment

# Strict mode
set -e
set -o pipefail

# Variables passed from the main script (already expanded)
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
ENABLE_DM="${ENABLE_DM}"
INSTALL_STEAM=${INSTALL_STEAM}
ENABLE_MULTILIB=${ENABLE_MULTILIB} # Pass the new variable
DEFAULT_REGION="${DEFAULT_REGION}"
DEFAULT_CITY="${DEFAULT_CITY}"
PARALLEL_DL_COUNT="${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}" # Get count from outer script or default

# Chroot Logging functions (redefined for clarity inside chroot)
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "\${C_BLUE}\${C_BOLD}[CHROOT INFO]\${C_OFF} \$1"; }
error() { echo -e "\${C_RED}\${C_BOLD}[CHROOT ERROR]\${C_OFF} \$1"; exit 1; } # Exit on error inside chroot
success() { echo -e "\${C_GREEN}\${C_BOLD}[CHROOT SUCCESS]\${C_OFF} \$1"; }
warn() { echo -e "\${C_YELLOW}\${C_BOLD}[CHROOT WARN]\${C_OFF} \$1"; }
check_status_chroot() {
    local status=\$?
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; fi
    return \$status
}

# --- Chroot Configuration Steps ---

info "Setting timezone to \${DEFAULT_REGION}/\${DEFAULT_CITY}..."
ln -sf "/usr/share/zoneinfo/\${DEFAULT_REGION}/\${DEFAULT_CITY}" /etc/localtime
check_status_chroot "Linking timezone"
hwclock --systohc # Set hardware clock from system time
check_status_chroot "Setting hardware clock (hwclock --systohc)"
success "Timezone set."

info "Configuring Locale (en_US.UTF-8)..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
# Add other locales if needed by uncommenting below
# echo "en_CA.UTF-8 UTF-8" >> /etc/locale.gen
# echo "fr_CA.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
check_status_chroot "Generating locales"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
success "Locale configured."

info "Setting hostname to '\${HOSTNAME}'..."
echo "\${HOSTNAME}" > /etc/hostname
# Configure /etc/hosts
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
EOF_HOSTS
check_status_chroot "Writing /etc/hosts"
success "Hostname set."

info "Setting root password..."
echo "root:\${ROOT_PASSWORD}" | chpasswd
check_status_chroot "Setting root password via chpasswd"
success "Root password set."

info "Creating user '\${USERNAME}' with Zsh shell..."
# Create user, home dir (-m), add to wheel group (-G), set shell (-s)
useradd -m -G wheel -s /bin/zsh "\${USERNAME}"
check_status_chroot "Creating user \${USERNAME}"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd
check_status_chroot "Setting password for \${USERNAME} via chpasswd"
success "User '\${USERNAME}' created, password set, added to 'wheel' group."

info "Configuring sudo for 'wheel' group..."
# Uncomment the '%wheel ALL=(ALL:ALL) ALL' line in /etc/sudoers
# Use visudo for safety if possible, but sed is common in scripts
if grep -q -E '^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    sed -i -E 's/^#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)/\1/' /etc/sudoers
    check_status_chroot "Uncommenting wheel group in sudoers"
    success "Sudo configured for 'wheel' group."
elif grep -q -E '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    warn "'wheel' group already uncommented in sudoers. No changes made."
else
    error "Could not find the wheel group line in /etc/sudoers to uncomment. Manual configuration needed."
fi

# === Ensure Pacman config (ParallelDownloads, Color, Multilib) is correct ===
info "Ensuring Pacman configuration inside chroot..."
# Re-apply ParallelDownloads and Color settings using sed (idempotent)
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

# Ensure Multilib is enabled IF Steam OR Enable Multilib was selected
if [[ "\${INSTALL_STEAM}" == "true" ]] || [[ "\${ENABLE_MULTILIB}" == "true" ]]; then
    info "Ensuring Multilib repository is enabled in chroot pacman.conf..."
    sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
    # sed -i '/^[[:space:]]*\[multilib\]/{ n; s/^[[:space:]]*#Include/Include/ }' /etc/pacman.conf # Simpler alternative
    check_status_chroot "Ensuring multilib is enabled in chroot pacman.conf"
fi
success "Pacman configuration verified."

info "Enabling NetworkManager service..."
systemctl enable NetworkManager.service
check_status_chroot "Enabling NetworkManager service"
success "NetworkManager enabled."

# Enable Display Manager if a desktop environment was selected
if [[ -n "\${ENABLE_DM}" ]]; then
    info "Enabling Display Manager service (\${ENABLE_DM})..."
    systemctl enable "\${ENABLE_DM}.service"
    check_status_chroot "Enabling \${ENABLE_DM} service"
    success "\${ENABLE_DM} enabled."
else
    info "No Display Manager to enable (Server install or manual setup selected)."
fi

# Enable SSHD if installed (typically for server installs)
if pacman -Qs openssh &>/dev/null; then
    info "OpenSSH package found, enabling sshd service..."
    systemctl enable sshd.service
    check_status_chroot "Enabling sshd service"
    success "sshd enabled."
fi

info "Updating initial ramdisk environment (mkinitcpio)..."
# -P uses all presets (common practice)
mkinitcpio -P
check_status_chroot "Running mkinitcpio -P"
success "Initramfs updated."

success "Chroot configuration script finished successfully."

CHROOT_SCRIPT_EOF
    check_status "Creating chroot configuration script"

    chmod +x /mnt/configure_chroot.sh
    check_status "Setting execute permissions on chroot script"

    info "Executing configuration script inside chroot environment..."
    # Run the script within the chroot
    arch-chroot /mnt /configure_chroot.sh
    check_status "Executing chroot configuration script"

    # Clean up the script file from the installed system
    info "Removing chroot configuration script..."
    rm /mnt/configure_chroot.sh
    check_status "Removing chroot script"

    success "System configuration inside chroot complete."
}

install_bootloader() {
    info "Installing and configuring GRUB bootloader for ${BOOT_MODE}..."

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Installing GRUB for UEFI..."
        # Install to EFI partition, specify bootloader ID
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
        check_status "Running grub-install for UEFI"
    else # BIOS
        info "Installing GRUB for BIOS/MBR on ${TARGET_DISK}..."
        # Install to the MBR of the target disk
        arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"
        check_status "Running grub-install for BIOS on ${TARGET_DISK}"
    fi

    info "Generating GRUB configuration file..."
    # Generate the grub.cfg file
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    check_status "Running grub-mkconfig"

    success "GRUB bootloader installed and configured."
}

install_oh_my_zsh() {
    # Check if zsh was installed (it's in base_pkgs now)
    if ! arch-chroot /mnt pacman -Qs zsh &>/dev/null; then
        warn "zsh package not found in chroot. Skipping Oh My Zsh installation."
        return
    fi

    if confirm "Install Oh My Zsh for user '${USERNAME}' and root? (Requires internet)"; then
        info "Installing Oh My Zsh (requires internet access within chroot)..."
        local user_home="/home/${USERNAME}"

        # Install for root user
        info "Installing Oh My Zsh for root..."
        # Use --unattended for non-interactive install. Export vars to prevent it from launching Zsh.
        # Try curl first, fallback to wget
        if ! arch-chroot /mnt sh -c 'export RUNZSH=no CHSH=no; sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then
            warn "curl failed for Oh My Zsh (root), trying wget..."
            if ! arch-chroot /mnt sh -c 'export RUNZSH=no CHSH=no; sh -c "$(wget -qO- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then
                error "Failed to download Oh My Zsh installer for root using curl and wget."
            else
                success "Oh My Zsh installed for root (using wget)."
                # Optionally set a default theme for root
                arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
            fi
        else
            success "Oh My Zsh installed for root (using curl)."
            arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
        fi

        # Install for the regular user
        info "Installing Oh My Zsh for user ${USERNAME}..."
        # Run as the user using sudo -u. Set HOME explicitly.
        if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            warn "curl failed for Oh My Zsh (${USERNAME}), trying wget..."
             if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(wget -qO- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
                 error "Failed to download Oh My Zsh installer for ${USERNAME} using curl and wget."
            else
                 success "Oh My Zsh installed for ${USERNAME} (using wget)."
                 # Set a different theme for the user, e.g., agnoster (requires powerline fonts)
                 arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"
                 warn "Set Zsh theme to 'agnoster' for ${USERNAME}. Install 'powerline-fonts' package after reboot for proper display."
            fi
        else
            success "Oh My Zsh installed for ${USERNAME} (using curl)."
            arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"
            warn "Set Zsh theme to 'agnoster' for ${USERNAME}. Install 'powerline-fonts' package after reboot for proper display."
        fi
        # Ensure correct ownership of user's files
        arch-chroot /mnt chown -R "${USERNAME}:${USERNAME}" "${user_home}"

    else
        info "Oh My Zsh will not be installed."
        info "User ${USERNAME}'s shell remains Zsh (set during user creation)."
        info "To change shell later, use: chsh -s /bin/bash ${USERNAME}"
    fi
}

final_steps() {
    success "Arch Linux installation process finished!"
    info "It is strongly recommended to review the installed system before rebooting."
    info "You can use 'arch-chroot /mnt' to enter the installed system and check configurations (e.g., /etc/fstab, users, services)."
    warn "Ensure you remove the installation medium (USB/CD/ISO) before rebooting."

    info "Attempting final unmount of filesystems..."
    sync # Sync filesystem buffers before unmounting
    # Attempt recursive unmount, use -l for lazy unmount as fallback, ignore errors
    umount -R /mnt &>/dev/null || umount -R -l /mnt &>/dev/null || true
    # Deactivate swap if it was used
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null || true
    success "Attempted unmount and swapoff. Verify with 'lsblk' or 'mount'."

    echo -e "${C_GREEN}${C_BOLD}"
    echo "----------------------------------------------------"
    echo " Installation finished at $(date)."
    echo " You can now type 'reboot' or 'shutdown now'."
    echo " Thank you for using this script!"
    echo "----------------------------------------------------"
    echo -e "${C_OFF}"
}

# --- Run the main function ---
main

# Explicitly exit with success code if main finishes without errors
exit 0
