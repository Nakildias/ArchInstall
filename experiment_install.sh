#!/bin/bash

# Arch Linux Installation Script - Reworked

# --- Configuration ---
SCRIPT_VERSION="2.2" # Incremented version for formatting path fix
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
DEFAULT_REGION="America" # Example default for timezone (Updated based on location context)
DEFAULT_CITY="Toronto"   # Example default for timezone (Updated based on location context)

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
        case "${yn,,}" in
            y|yes) return 0 ;;
            n|no|"" ) return 1 ;;
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
}

# --- Script Logic ---

main() {
    # Initial setup
    setup_environment

    # Pre-installation checks
    check_boot_mode
    check_internet

    # User configuration gathering
    select_disk
    configure_partitioning # Determines PART_PREFIX correctly now
    configure_hostname_user
    select_kernel
    select_desktop_environment
    select_optional_packages

    # Perform installation steps
    configure_mirrors
    partition_and_format      # Fixed mkfs calls
    mount_filesystems         # Fixed mount/swapon calls
    install_base_system
    configure_installed_system
    install_bootloader        # Already correct for TARGET_DISK
    install_oh_my_zsh

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
    sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true # Ignore errors if disk is already clean
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
    if [[ "$TARGET_DISK" == *nvme* ]]; then
        # For nvme disks like /dev/nvme0n1, partitions are /dev/nvme0n1p1, p2 etc.
        PART_PREFIX="${TARGET_DISK}p"
    else
        # For SATA/SCSI disks like /dev/sda, partitions are /dev/sda1, sda2 etc.
        PART_PREFIX="${TARGET_DISK}"
    fi
     # Now PART_PREFIX will correctly form /dev/sda or /dev/nvme0n1p when partition number is added
    info "Partition name prefix determined: ${PART_PREFIX}" # Debugging info
}

configure_hostname_user() {
    info "Configuring system identity..."
    while true; do
        prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
        [[ -n "$HOSTNAME" && ! "$HOSTNAME" =~ \ |\' ]] && break || error "Hostname cannot be empty and should not contain spaces or quotes."
    done

    while true; do
        prompt "Enter username for the primary user: " USERNAME
        if [[ -n "$USERNAME" && ! "$USERNAME" =~ \ |\' ]]; then
             info "Username set to: ${USERNAME}"
            break
        else
            error "Username cannot be empty and should not contain spaces or quotes."
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
            SELECTED_DE_INDEX=$((REPLY - 1))
            info "Selected environment: ${C_BOLD}${SELECTED_DE_NAME}${C_OFF}"
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

    if confirm "Install Steam?"; then
        INSTALL_STEAM=true
        info "Steam will be installed (requires enabling multilib repository)."
    fi

    if confirm "Install Discord?"; then
        INSTALL_DISCORD=true
        info "Discord will be installed."
    fi
}

configure_mirrors() {
    info "Configuring Pacman mirrors for optimal download speed..."
    warn "This may take a few moments."

    # Backup original mirrorlist
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    check_status "Backing up mirrorlist"

    # Getting current country based on IP for reflector (requires curl)
    # Using ipinfo.io - make sure curl is available on ISO
    info "Attempting to detect country for mirror selection..."
    CURRENT_COUNTRY_CODE=$(curl -s --connect-timeout 5 ipinfo.io/country)
    if [[ -n "$CURRENT_COUNTRY_CODE" ]] && [[ ${#CURRENT_COUNTRY_CODE} -eq 2 ]]; then
         info "Detected country code: ${CURRENT_COUNTRY_CODE}. Using it for reflector."
         REFLECTOR_COUNTRIES="--country ${CURRENT_COUNTRY_CODE}"
    else
         warn "Could not detect country code automatically. Using default countries (Canada)."
         REFLECTOR_COUNTRIES="--country Canada" # Fallback country based on current location context
    fi

    # Run reflector: latest 20, HTTPS only, sort by download rate, save to mirrorlist
    reflector --verbose ${REFLECTOR_COUNTRIES} --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
    check_status "Running reflector"

    success "Mirrorlist updated."

    # Enable parallel downloads & Color
    if confirm "Enable parallel downloads in pacman? (Recommended)"; then
         while true; do
            prompt "How many parallel downloads? (1-10, default: ${DEFAULT_PARALLEL_DL}): " PARALLEL_DL_COUNT
            PARALLEL_DL_COUNT=${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}
            if [[ "$PARALLEL_DL_COUNT" =~ ^[1-9]$|^10$ ]]; then
                info "Setting parallel downloads to ${PARALLEL_DL_COUNT}."
                # Use more robust sed for ParallelDownloads
                if grep -q -E "^#[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
                    sed -i -E "s/^[[:space:]]*#[[:space:]]*ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                elif ! grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf; then
                    echo "ParallelDownloads = ${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
                else
                     sed -i -E "s/^[[:space:]]*ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                fi
                # Use more robust sed for Color
                 if grep -q -E "^#[[:space:]]*Color" /etc/pacman.conf; then
                    sed -i -E "s/^[[:space:]]*#[[:space:]]*Color.*/Color/" /etc/pacman.conf
                elif ! grep -q -E "^[[:space:]]*Color" /etc/pacman.conf; then
                    echo "Color" >> /etc/pacman.conf
                fi
                break
            else
                error "Please enter a number between 1 and 10."
            fi
        done
    else
        info "Parallel downloads disabled."
        sed -i -E 's/^[[:space:]]*ParallelDownloads/#ParallelDownloads/' /etc/pacman.conf
    fi

    # Enable Multilib if Steam is selected
    if $INSTALL_STEAM; then
        info "Enabling Multilib repository for Steam..."
        # Make sed idempotent: only uncomment if commented
        sed -i '/\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf
        check_status "Enabling multilib repo"
        success "Multilib repository enabled."
    else
        info "Multilib repository remains disabled."
    fi

    # Refresh package databases with new mirrors and settings
    info "Synchronizing package databases..."
    pacman -Syy
    check_status "pacman -Syy"
}

# --- !!! THIS FUNCTION HAS BEEN MODIFIED TO FIX FORMATTING PATHS !!! ---
partition_and_format() {
    info "Partitioning ${TARGET_DISK} for ${BOOT_MODE}..."

    # Partitioning using parted
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Creating GPT partition table for UEFI on ${TARGET_DISK}..."
        parted -s "${TARGET_DISK}" -- \
            mklabel gpt \
            mkpart ESP fat32 1MiB "${BOOT_PART_SIZE}" \
            set 1 esp on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning disk ${TARGET_DISK} with GPT for UEFI"
        # Assign partition numbers for UEFI/GPT
        # PART_PREFIX already includes /dev/... or /dev/...p
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
        sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true # Ensure GPT is gone
        parted -s "${TARGET_DISK}" -- \
            mklabel msdos \
            mkpart primary ext4 1MiB "${BOOT_PART_SIZE}" \
            set 1 boot on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning disk ${TARGET_DISK} with MBR for BIOS"
        # Assign partition numbers for BIOS/MBR
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
    lsblk "${TARGET_DISK}"
    confirm "Proceed with formatting?" || { error "Formatting cancelled."; exit 1; }


    # --- Formatting (Fixed paths) ---
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


# --- !!! THIS FUNCTION HAS BEEN MODIFIED TO FIX MOUNT/SWAPON PATHS !!! ---
mount_filesystems() {
    info "Mounting filesystems..."
    # Use partition variables directly
    mount "${ROOT_PARTITION}" /mnt
    check_status "Mounting root partition ${ROOT_PARTITION}"

    # Mount boot partition under /mnt/boot
    # mount --mkdir handles creating /mnt/boot if needed
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot
    check_status "Mounting boot partition ${BOOT_PARTITION} at /mnt/boot"

    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "${SWAP_PARTITION}"
        check_status "Activating swap partition ${SWAP_PARTITION}"
    fi
    success "Filesystems mounted."
    # Verify mounts
    findmnt /mnt
    findmnt /mnt/boot
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
            de_pkgs+=("openssh")
            ;;
        1) # KDE Plasma
            de_pkgs+=( "plasma-desktop" "sddm" "konsole" "dolphin" "gwenview" "ark" "kcalc" "spectacle" "kate" "kscreen" "flatpak" "discover" "partitionmanager" "p7zip" "firefox" "plasma-nm" )
            ENABLE_DM="sddm"
            ;;
        2) # GNOME
            de_pkgs+=( "gnome" "gdm" "gnome-terminal" "nautilus" "gnome-text-editor" "gnome-control-center" "gnome-software" "eog" "file-roller" "flatpak" "firefox" "gnome-shell-extensions" "gnome-tweaks" ) # Added tweaks
            ENABLE_DM="gdm"
            ;;
        3) # XFCE
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
    if grep -qE '/dev/(sd|nvme|vd)' /mnt/etc/fstab; then
         warn "/etc/fstab seems to contain device names. UUIDs/LABELS recommended. Check /mnt/etc/fstab."
    fi
    success "fstab generated (/mnt/etc/fstab)."


    # Copy necessary config files into chroot environment
    info "Copying Pacman configuration to chroot environment..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    check_status "Copying mirrorlist to /mnt"
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    check_status "Copying pacman.conf to /mnt"


    # Create chroot configuration script using Heredoc
    cat <<CHROOT_SCRIPT_EOF > /mnt/configure_chroot.sh
#!/bin/bash
set -e
set -o pipefail

# Variables passed from main script (already expanded by outer shell)
HOSTNAME="${HOSTNAME}"
USERNAME="${USERNAME}"
USER_PASSWORD="${USER_PASSWORD}"
ROOT_PASSWORD="${ROOT_PASSWORD}"
ENABLE_DM="${ENABLE_DM}"
INSTALL_STEAM=${INSTALL_STEAM}
DEFAULT_REGION="${DEFAULT_REGION}"
DEFAULT_CITY="${DEFAULT_CITY}"
PARALLEL_DL_COUNT="${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}"

# Chroot Logging functions
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "\${C_BLUE}\${C_BOLD}[CHROOT INFO]\${C_OFF} \$1"; }
error() { echo -e "\${C_RED}\${C_BOLD}[CHROOT ERROR]\${C_OFF} \$1"; }
success() { echo -e "\${C_GREEN}\${C_BOLD}[CHROOT SUCCESS]\${C_OFF} \$1"; }
warn() { echo -e "\${C_YELLOW}\${C_BOLD}[WARN]\${C_OFF} \$1"; }
check_status_chroot() {
    local status=\$?
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; exit 1; fi
    return \$status
}

# --- Chroot Configuration Steps ---

info "Setting timezone (\${DEFAULT_REGION}/\${DEFAULT_CITY})..."
ln -sf "/usr/share/zoneinfo/\${DEFAULT_REGION}/\${DEFAULT_CITY}" /etc/localtime
check_status_chroot "Linking timezone"
hwclock --systohc
check_status_chroot "Setting hardware clock"
success "Timezone set."

info "Configuring Locale (en_US.UTF-8)..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
# Add other common locales - uncomment if needed
# echo "en_CA.UTF-8 UTF-8" >> /etc/locale.gen
# echo "fr_CA.UTF-8 UTF-8" >> /etc/locale.gen
# echo "fr_FR.UTF-8 UTF-8" >> /etc/locale.gen
locale-gen
check_status_chroot "Generating locales"
echo "LANG=en_US.UTF-8" > /etc/locale.conf
success "Locale configured."

info "Setting hostname (\${HOSTNAME})..."
echo "\${HOSTNAME}" > /etc/hostname
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
EOF_HOSTS
success "Hostname set."

info "Setting root password..."
echo "root:\${ROOT_PASSWORD}" | chpasswd
check_status_chroot "Setting root password"
success "Root password set."

info "Creating user \${USERNAME}..."
useradd -m -G wheel -s /bin/zsh "\${USERNAME}"
check_status_chroot "Creating user \${USERNAME}"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd
check_status_chroot "Setting password for \${USERNAME}"
success "User \${USERNAME} created and password set."

info "Configuring sudo for wheel group..."
if grep -q -E '^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    sed -i -E 's/^#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)/\1/' /etc/sudoers
    check_status_chroot "Uncommenting wheel group in sudoers"
    success "Sudo configured for wheel group."
elif grep -q -E '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    warn "Wheel group already uncommented in sudoers."
else
    error "Could not find wheel group line in /etc/sudoers to uncomment."
fi

info "Ensuring Pacman config (ParallelDownloads=\${PARALLEL_DL_COUNT}, Color=On)..."
# Use robust sed to ensure settings are applied correctly
sed -i -E -e "s/^[[:space:]]*#[[:space:]]*ParallelDownloads.*/ParallelDownloads = \${PARALLEL_DL_COUNT}/" \
          -e "/^[[:space:]]*ParallelDownloads/!{ \$a\\ParallelDownloads = \${PARALLEL_DL_COUNT} }" \
          -e "s/^[[:space:]]*ParallelDownloads.*/ParallelDownloads = \${PARALLEL_DL_COUNT}/" \
          -e "s/^[[:space:]]*#[[:space:]]*Color.*/Color/" \
          -e "/^[[:space:]]*Color/!{ \$a\\Color }" \
          /etc/pacman.conf

if [[ "\${INSTALL_STEAM}" == "true" ]]; then
    info "Ensuring Multilib repository is enabled inside chroot..."
    sed -i '/\[multilib\]/{n;s/^#Include/Include/}' /etc/pacman.conf
fi

info "Enabling NetworkManager service..."
systemctl enable NetworkManager
check_status_chroot "Enabling NetworkManager service"
success "NetworkManager enabled."

if [[ -n "\${ENABLE_DM}" ]]; then
    info "Enabling Display Manager service (\${ENABLE_DM})..."
    systemctl enable "\${ENABLE_DM}.service"
    check_status_chroot "Enabling \${ENABLE_DM} service"
    success "\${ENABLE_DM} enabled."
else
    info "No Display Manager to enable (Server install)."
fi

if pacman -Qs openssh &>/dev/null; then
     info "OpenSSH package found, enabling sshd service..."
     systemctl enable sshd
     check_status_chroot "Enabling sshd service"
     success "sshd enabled."
fi

info "Updating initial ramdisk environment (mkinitcpio)..."
mkinitcpio -P
check_status_chroot "Running mkinitcpio -P"
success "Initramfs updated."

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
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
        check_status "Running grub-install for UEFI"
    else # BIOS
        # TARGET_DISK already contains /dev/..., so use it directly
        arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"
        check_status "Running grub-install for BIOS on ${TARGET_DISK}"
    fi

    info "Generating GRUB configuration file..."
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    check_status "Running grub-mkconfig"

    success "GRUB bootloader installed and configured."
}

install_oh_my_zsh() {
    if confirm "Install Oh My Zsh for user '${USERNAME}' and root?"; then
        info "Installing Oh My Zsh (requires internet access within chroot)..."
        local user_home="/home/${USERNAME}"

        # Install for root user
        info "Installing Oh My Zsh for root..."
        if ! arch-chroot /mnt sh -c 'export RUNZSH=no; export CHSH=no; sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then
             warn "curl failed for Oh My Zsh (root), trying wget..."
             if ! arch-chroot /mnt sh -c 'export RUNZSH=no; export CHSH=no; sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then
                 error "Failed to install Oh My Zsh for root."
             else
                 success "Oh My Zsh installed for root (wget)."
                 arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
             fi
        else
             success "Oh My Zsh installed for root (curl)."
             arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
        fi

        # Install for the regular user
        info "Installing Oh My Zsh for user ${USERNAME}..."
        if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
             warn "curl failed for Oh My Zsh (${USERNAME}), trying wget..."
             if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
                error "Failed to install Oh My Zsh for ${USERNAME}."
            else
                 success "Oh My Zsh installed for ${USERNAME} (wget)."
                 arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"
                 warn "User ${USERNAME}'s shell is Zsh. Install 'powerline-fonts' package for themes like 'agnoster'."
             fi
        else
             success "Oh My Zsh installed for ${USERNAME} (curl)."
             arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"
             warn "User ${USERNAME}'s shell is Zsh. Install 'powerline-fonts' package for themes like 'agnoster'."
        fi
    else
        info "Oh My Zsh will not be installed."
        info "Setting user ${USERNAME}'s shell back to /bin/bash."
        arch-chroot /mnt chsh -s /bin/bash "${USERNAME}"
        check_status "Setting ${USERNAME}'s shell to bash"
    fi
}

final_steps() {
    success "Arch Linux installation appears complete!"
    info "It is recommended to review the installed system before rebooting."
    info " Use 'arch-chroot /mnt' to explore (check /etc/fstab, users, services)."
    warn "Remember to remove the installation medium before rebooting."

    info "Attempting final unmount of filesystems..."
    sync # Sync filesystem buffers before unmounting
    umount -R /mnt &>/dev/null || umount -R -l /mnt &>/dev/null || true
    # Use parameter expansion check for swap variable
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null || true
    success "Attempted unmount. Check with 'lsblk' or 'findmnt'."

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
