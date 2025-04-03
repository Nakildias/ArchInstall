#!/bin/bash

# Arch Linux Installation Script - Reworked

# --- Configuration ---
SCRIPT_VERSION="2.0"
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
DEFAULT_REGION="Europe" # Example default for timezone
DEFAULT_CITY="London"   # Example default for timezone

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
prompt() { read -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} $1")" "$2"; }
confirm() {
    while true; do
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
    if [ $? -ne 0 ]; then
        error "Command failed: $1"
        # Optional: Add cleanup logic here if needed
        exit 1
    fi
}

# Exit handler
trap 'cleanup' EXIT SIGHUP SIGINT SIGTERM
cleanup() {
    info "Performing cleanup..."
    # Attempt to unmount everything in reverse order in case of script failure
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    # Deactivate swap if it was activated
    [[ -n "$SWAP_PARTITION" ]] && swapoff "/dev/$SWAP_PARTITION" &>/dev/null
    info "Cleanup finished. If the script failed, some resources might still be mounted."
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
    configure_partitioning
    configure_hostname_user
    select_kernel
    select_desktop_environment
    select_optional_packages

    # Perform installation steps
    configure_mirrors
    partition_and_format
    mount_filesystems
    install_base_system
    configure_installed_system
    install_bootloader
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
    if ping -c 1 archlinux.org &> /dev/null; then
        success "Internet connection available."
    else
        error "No internet connection detected. Please connect to the internet and restart the script."
        exit 1
    fi
}

select_disk() {
    info "Detecting available block devices..."
    mapfile -t devices < <(lsblk -dnpo name,type,size | awk '$2=="disk"{print $1" ("$3")"}')

    if [ ${#devices[@]} -eq 0 ]; then
        error "No disks found. Ensure drives are properly connected."
        exit 1
    fi

    echo "Available disks:"
    select device_choice in "${devices[@]}"; do
        if [[ -n "$device_choice" ]]; then
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
    sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true # Ignore errors if disk is already clean
    check_status "Wiping disk ${TARGET_DISK}"
    success "Disk ${TARGET_DISK} wiped."
}

configure_partitioning() {
    info "Configuring partition layout for ${BOOT_MODE} mode."

    # Boot Partition Size
    while true; do
        prompt "Enter Boot Partition size (e.g., 550M, 1G) [${MIN_BOOT_SIZE_MB}M minimum, recommended 550M+]: " BOOT_SIZE_INPUT
        # Basic validation (simplistic, adjust regex for more complex checks)
        if [[ "$BOOT_SIZE_INPUT" =~ ^[0-9]+[MG]$ ]]; then
            # Convert to MB for comparison
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
        prompt "Enter Swap size (e.g., 4G, 512M, leave blank for NO swap): " SWAP_SIZE_INPUT
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
    if [[ "$TARGET_DISK" == *nvme* ]]; then
        PART_PREFIX="${TARGET_DISK}p"
    else
        PART_PREFIX="${TARGET_DISK}"
    fi
}

configure_hostname_user() {
    info "Configuring system identity..."
    while true; do
        prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
        [[ -n "$HOSTNAME" ]] && break || error "Hostname cannot be empty."
    done

    while true; do
        prompt "Enter username for the primary user: " USERNAME
        [[ -n "$USERNAME" ]] && break || error "Username cannot be empty."
    done

    while true; do
        prompt "Enter password for user '${USERNAME}': " -s USER_PASSWORD
        echo
        prompt "Confirm password for user '${USERNAME}': " -s USER_PASSWORD_CONFIRM
        echo
        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]] && [[ -n "$USER_PASSWORD" ]]; then
            break
        else
            error "Passwords do not match or are empty. Please try again."
        fi
    done

    while true; do
        prompt "Enter password for the root user: " -s ROOT_PASSWORD
        echo
        prompt "Confirm root password: " -s ROOT_PASSWORD_CONFIRM
        echo
        if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]] && [[ -n "$ROOT_PASSWORD" ]]; then
            break
        else
            error "Passwords do not match or are empty. Please try again."
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
        "LXQt" # Replaced LXDE with more modern LXQt
        "MATE"
    )
    echo "Available environments:"
    select de_choice in "${desktops[@]}"; do
        if [[ -n "$de_choice" ]]; then
            SELECTED_DE_NAME=$de_choice
            # Extract numerical index based on REPLY
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

    # Use reflector to get the fastest mirrors (adjust countries as needed)
    # Consider adding more options like --sort rate, --protocol https etc.
    reflector --verbose --country 'Canada,United States' --latest 10 --sort rate --save /etc/pacman.d/mirrorlist
    check_status "Running reflector"

    success "Mirrorlist updated."

    # Enable parallel downloads
    if confirm "Enable parallel downloads in pacman? (Recommended)"; then
         while true; do
            prompt "How many parallel downloads? (1-10, default: ${DEFAULT_PARALLEL_DL}): " PARALLEL_DL_COUNT
            PARALLEL_DL_COUNT=${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}
            if [[ "$PARALLEL_DL_COUNT" =~ ^[1-9]$|^10$ ]]; then
                info "Setting parallel downloads to ${PARALLEL_DL_COUNT}."
                # Use grep/sed to uncomment or add the ParallelDownloads line
                if grep -q "^#ParallelDownloads" /etc/pacman.conf; then
                    sed -i "s/^#ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                elif ! grep -q "^ParallelDownloads" /etc/pacman.conf; then
                    echo "ParallelDownloads = ${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
                else
                     sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                fi
                # Enable Color
                 if grep -q "^#Color" /etc/pacman.conf; then
                    sed -i "s/^#Color/Color/" /etc/pacman.conf
                elif ! grep -q "^Color" /etc/pacman.conf; then
                    echo "Color" >> /etc/pacman.conf
                fi
                break
            else
                error "Please enter a number between 1 and 10."
            fi
        done
    else
        info "Parallel downloads disabled."
        # Ensure it's commented out if it exists
        sed -i 's/^ParallelDownloads/#ParallelDownloads/' /etc/pacman.conf
    fi
     # Enable Multilib if Steam is selected
    if $INSTALL_STEAM; then
        info "Enabling Multilib repository for Steam..."
        sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
        check_status "Enabling multilib repo"
        success "Multilib repository enabled."
    fi

    # Refresh package databases with new mirrors and settings
    info "Synchronizing package databases..."
    pacman -Syy
    check_status "pacman -Syy"
}

partition_and_format() {
    info "Partitioning ${TARGET_DISK} for ${BOOT_MODE}..."

    # Partitioning
    parted -s "${TARGET_DISK}" -- \
        mklabel ${BOOT_MODE,,} \
        $( [[ "$BOOT_MODE" == "UEFI" ]] && \
           echo "mkpart ESP fat32 1MiB ${BOOT_PART_SIZE} set 1 esp on" || \
           # BIOS with GPT needs bios_grub, BIOS with MBR needs boot flag
           # Using GPT for consistency here
           echo "mkpart primary 1MiB 2MiB set 1 bios_grub on" \
           echo "mkpart primary fat32 2MiB ${BOOT_PART_SIZE}" \
        ) \
        $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
        mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%

    check_status "Partitioning disk ${TARGET_DISK}"

    # Assign partition variables based on BOOT_MODE and presence of SWAP
    local part_num_boot=1
    local part_num_swap=2
    local part_num_root=3

    if [[ "$BOOT_MODE" == "BIOS" ]]; then
        # BIOS/GPT: 1=bios_grub, 2=boot (placeholder/unused by grub typically), 3=swap, 4=root
        # Adjusting logic to use a single boot partition for simplicity if possible
        # Let's simplify: BIOS/GPT needs bios_grub, but we don't need a separate FAT32 /boot unless chainloading?
        # Let's try MBR for BIOS for simplicity, avoids bios_grub partition.
        info "Re-partitioning ${TARGET_DISK} for BIOS/MBR..."
        sgdisk --zap-all "${TARGET_DISK}" # Clear GPT first
        parted -s "${TARGET_DISK}" -- \
            mklabel msdos \
            mkpart primary ext4 1MiB ${BOOT_PART_SIZE} set 1 boot on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning disk ${TARGET_DISK} with MBR"
        part_num_boot=1
        part_num_swap=2
        part_num_root=3
         if [[ -z "$SWAP_PART_SIZE" ]]; then part_num_root=2; fi # Root becomes 2nd partition if no swap
    else # UEFI
        # UEFI/GPT: 1=EFI, 2=Swap, 3=Root
        part_num_boot=1
        part_num_swap=2
        part_num_root=3
        if [[ -z "$SWAP_PART_SIZE" ]]; then part_num_root=2; fi # Root becomes 2nd partition if no swap
    fi


    BOOT_PARTITION="${PART_PREFIX}${part_num_boot}"
    if [[ -n "$SWAP_PART_SIZE" ]]; then
        SWAP_PARTITION="${PART_PREFIX}${part_num_swap}"
    else
        SWAP_PARTITION="" # Ensure it's empty if no swap
    fi
    ROOT_PARTITION="${PART_PREFIX}${part_num_root}"

    info "Disk layout planned:"
    info " Boot: /dev/${BOOT_PARTITION}"
    [[ -n "$SWAP_PARTITION" ]] && info " Swap: /dev/${SWAP_PARTITION}"
    info " Root: /dev/${ROOT_PARTITION}"
    lsblk "${TARGET_DISK}"
    confirm "Proceed with formatting?" || { error "Formatting cancelled."; exit 1; }


    # Formatting
    info "Formatting partitions..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        mkfs.fat -F32 "/dev/${BOOT_PARTITION}"
        check_status "Formatting EFI partition /dev/${BOOT_PARTITION}"
    else # BIOS/MBR
        # Boot partition might be ext4 or fat32 depending on preference. Ext4 is fine for GRUB.
        mkfs.ext4 -F "/dev/${BOOT_PARTITION}" # Using Ext4 for /boot in BIOS mode
        check_status "Formatting Boot partition /dev/${BOOT_PARTITION}"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        mkswap "/dev/${SWAP_PARTITION}"
        check_status "Formatting Swap partition /dev/${SWAP_PARTITION}"
    fi

    mkfs.ext4 -F "/dev/${ROOT_PARTITION}"
    check_status "Formatting Root partition /dev/${ROOT_PARTITION}"

    success "Partitions formatted."
}

mount_filesystems() {
    info "Mounting filesystems..."
    mount "/dev/${ROOT_PARTITION}" /mnt
    check_status "Mounting root partition"

    # Create mount points within the new root
    mkdir -p /mnt/boot
    check_status "Creating /mnt/boot directory"

    mount "/dev/${BOOT_PARTITION}" /mnt/boot
    check_status "Mounting boot partition"

    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "/dev/${SWAP_PARTITION}"
        check_status "Activating swap partition"
    fi
    success "Filesystems mounted."
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
        "btop" "fastfetch"
    )
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        base_pkgs+=("efibootmgr")
    fi
    [[ -n "$MICROCODE_PACKAGE" ]] && base_pkgs+=("$MICROCODE_PACKAGE")

    # Desktop Environment packages
    local de_pkgs=()
    case $SELECTED_DE_INDEX in
        0) # Server
            info "No GUI packages selected (Server install)."
            de_pkgs+=("openssh") # Common for servers
            ;;
        1) # KDE Plasma
            de_pkgs+=(
                "plasma-desktop" "sddm" "konsole" "dolphin" "gwenview"
                "ark" "kcalc" "spectacle" "kate" "kscreen" "flatpak" "discover"
                "partitionmanager" "p7zip" "firefox"
            )
            ENABLE_DM="sddm"
            ;;
        2) # GNOME
            de_pkgs+=(
                "gnome" "gdm" "gnome-terminal" "nautilus" "gnome-text-editor"
                "gnome-control-center" "gnome-software" "eog" "file-roller"
                "flatpak" "firefox"
            )
            ENABLE_DM="gdm"
            ;;
        3) # XFCE
             de_pkgs+=(
                 "xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter"
                 "xfce4-terminal" "thunar" "mousepad" "ristretto"
                 "file-roller" "flatpak" "firefox"
            )
            ENABLE_DM="lightdm"
            ;;
        4) # LXQt
             de_pkgs+=(
                 "lxqt" "sddm" # LXQt often uses SDDM or LightDM, choosing SDDM here
                 "qterminal" "pcmanfm-qt" "featherpad" "lximage-qt"
                 "ark" # Using ark for archives
                 "flatpak" "firefox"
             )
             ENABLE_DM="sddm"
            ;;
        5) # MATE
             de_pkgs+=(
                 "mate" "mate-extra" "lightdm" "lightdm-gtk-greeter" # Or use GDM if preferred
                 "mate-terminal" "caja" "pluma" "eom"
                 "engrampa" "flatpak" "firefox"
             )
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
    # Verify fstab entries (optional basic check)
    grep -q '/dev/ROOT_PARTITION' /mnt/etc/fstab && error "fstab might contain device names instead of UUIDs. Check /mnt/etc/fstab." || true

    # Copy necessary variables and the configuration script into chroot
    # This avoids passing many arguments to arch-chroot
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    cp /etc/pacman.conf /mnt/etc/pacman.conf

    # Create a script to run inside chroot
    cat <<CHROOT_SCRIPT > /mnt/configure_chroot.sh
#!/bin/bash
set -e # Exit on error within chroot script

# Color definitions for chroot script
C_OFF='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_PURPLE='\033[0;35m'
C_BOLD='\033[1m'

info() { echo -e "${C_BLUE}${C_BOLD}[CHROOT INFO]${C_OFF} \$1"; }
error() { echo -e "${C_RED}${C_BOLD}[CHROOT ERROR]${C_OFF} \$1"; }
success() { echo -e "${C_GREEN}${C_BOLD}[CHROOT SUCCESS]${C_OFF} \$1"; }
warn() { echo -e "${C_YELLOW}${C_BOLD}[WARN]${C_OFF} \$1"; }

# --- Configuration passed from main script ---
HOSTNAME="$HOSTNAME"
USERNAME="$USERNAME"
USER_PASSWORD="$USER_PASSWORD"
ROOT_PASSWORD="$ROOT_PASSWORD"
ENABLE_DM="$ENABLE_DM" # Display manager service name (sddm, gdm, lightdm) or empty
INSTALL_STEAM=$INSTALL_STEAM

# --- Chroot Configuration Steps ---

# Timezone
info "Setting timezone..."
# Consider using timedatectl list-timezones interactively here if desired
# Using predefined defaults for now
ln -sf "/usr/share/zoneinfo/${DEFAULT_REGION}/${DEFAULT_CITY}" /etc/localtime
check_status "Linking timezone"
hwclock --systohc # Set hardware clock from system clock
check_status "Setting hardware clock"
success "Timezone set to ${DEFAULT_REGION}/${DEFAULT_CITY}."

# Locale
info "Configuring Locale..."
LOCALE_CHOICE="en_US.UTF-8" # Default, consider making this selectable
info "Setting locale to ${LOCALE_CHOICE}"
echo "${LOCALE_CHOICE} UTF-8" > /etc/locale.gen
# Uncomment other locales if needed based on user input
# Example: sed -i 's/^#fr_FR.UTF-8/fr_FR.UTF-8/' /etc/locale.gen
locale-gen
check_status "Generating locales"
echo "LANG=${LOCALE_CHOICE}" > /etc/locale.conf
success "Locale configured."

# Hostname
info "Setting hostname..."
echo "${HOSTNAME}" > /etc/hostname
# Configure /etc/hosts
cat <<EOF > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   ${HOSTNAME}.localdomain ${HOSTNAME}
EOF
success "Hostname set to ${HOSTNAME}."

# Root Password
info "Setting root password..."
echo "root:${ROOT_PASSWORD}" | chpasswd
check_status "Setting root password"
success "Root password set."

# Create User
info "Creating user ${USERNAME}..."
# Create user with home directory, add to wheel group, set default shell to zsh
useradd -m -G wheel -s /bin/zsh "${USERNAME}"
check_status "Creating user ${USERNAME}"
echo "${USERNAME}:${USER_PASSWORD}" | chpasswd
check_status "Setting password for ${USERNAME}"
success "User ${USERNAME} created and password set."

# Sudoers configuration (uncomment wheel group)
info "Configuring sudo (granting wheel group privileges)..."
# Use visudo for safety in real scenarios, but sed is common in scripts
if grep -q '^# %wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    sed -i 's/^# %wheel ALL=(ALL:ALL) ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    check_status "Uncommenting wheel group in sudoers"
    success "Sudo configured for wheel group."
elif grep -q '^%wheel ALL=(ALL:ALL) ALL' /etc/sudoers; then
    warn "Wheel group already uncommented in sudoers."
else
    error "Could not find wheel group line in /etc/sudoers to uncomment."
    # Optionally add the line if it's completely missing
    # echo '%wheel ALL=(ALL:ALL) ALL' >> /etc/sudoers
fi


# Pacman Configuration (ensure parallel downloads and color are set inside chroot too)
info "Ensuring pacman configuration inside chroot..."
if grep -q "^#ParallelDownloads" /etc/pacman.conf; then
    sed -i "s/^#ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}/" /etc/pacman.conf
elif ! grep -q "^ParallelDownloads" /etc/pacman.conf; then
    echo "ParallelDownloads = ${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}" >> /etc/pacman.conf
else
     sed -i "s/^ParallelDownloads.*/ParallelDownloads = ${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}/" /etc/pacman.conf
fi
if grep -q "^#Color" /etc/pacman.conf; then
    sed -i "s/^#Color/Color/" /etc/pacman.conf
elif ! grep -q "^Color" /etc/pacman.conf; then
    echo "Color" >> /etc/pacman.conf
fi
# Enable Multilib if Steam is selected
if $INSTALL_STEAM; then
    info "Ensuring Multilib repository is enabled inside chroot..."
    sed -i "/\[multilib\]/,/Include/"'s/^#//' /etc/pacman.conf
fi
pacman -Syy # Refresh databases inside chroot if config changed


# Enable essential services
info "Enabling essential system services..."
systemctl enable NetworkManager
check_status "Enabling NetworkManager service"
success "NetworkManager enabled."

# Enable Display Manager if a DE was selected
if [[ -n "$ENABLE_DM" ]]; then
    info "Enabling Display Manager service (${ENABLE_DM})..."
    systemctl enable "${ENABLE_DM}.service"
    check_status "Enabling ${ENABLE_DM} service"
    success "${ENABLE_DM} enabled."
else
    info "No Display Manager to enable (Server install)."
fi

# Optional: Enable SSH if installed (e.g., for Server)
if pacman -Qs openssh &>/dev/null; then
     if confirm "Enable SSH service (sshd)?"; then
        systemctl enable sshd
        check_status "Enabling sshd service"
        success "sshd enabled."
    fi
fi

# Update initramfs (important after potential changes like microcode)
info "Updating initial ramdisk environment..."
mkinitcpio -P # Regenerate all presets
check_status "Running mkinitcpio -P"
success "Initramfs updated."


success "Chroot configuration script finished."

CHROOT_SCRIPT

    chmod +x /mnt/configure_chroot.sh
    check_status "Setting execute permissions on chroot script"

    # Execute the script within arch-chroot
    arch-chroot /mnt /configure_chroot.sh
    check_status "Executing chroot configuration script"

    # Clean up the script
    rm /mnt/configure_chroot.sh

    success "System configuration inside chroot complete."
}


install_bootloader() {
    info "Installing and configuring GRUB bootloader for ${BOOT_MODE}..."

    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH
        check_status "Running grub-install for UEFI"
    else # BIOS
        arch-chroot /mnt grub-install --target=i386-pc "${TARGET_DISK}"
        check_status "Running grub-install for BIOS on ${TARGET_DISK}"
    fi

    # Generate GRUB config
    arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
    check_status "Running grub-mkconfig"

    success "GRUB bootloader installed and configured."
}

install_oh_my_zsh() {
    if confirm "Install Oh My Zsh for user '${USERNAME}' and root?"; then
        info "Installing Oh My Zsh..."

        # Install for root user
        info "Installing Oh My Zsh for root..."
        arch-chroot /mnt sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || \
        arch-chroot /mnt sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        check_status "Installing Oh My Zsh for root"
        # Optionally set a theme for root
        arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc
        success "Oh My Zsh installed for root."


        # Install for the regular user
        info "Installing Oh My Zsh for user ${USERNAME}..."
        # Need to run the installer as the user
        arch-chroot /mnt sudo -u "${USERNAME}" sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended || \
        arch-chroot /mnt sudo -u "${USERNAME}" sh -c "$(wget -qO- https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        check_status "Installing Oh My Zsh for ${USERNAME}"
        # Optionally set a theme for the user
        arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "/home/${USERNAME}/.zshrc" # Example theme
        warn "User ${USERNAME}'s default shell is now Zsh. Consider installing powerline fonts (e.g., 'powerline-fonts' package) for themes like 'agnoster'."
        success "Oh My Zsh installed for ${USERNAME}."
    else
        info "Oh My Zsh will not be installed."
        # Ensure user's shell is bash if OMZ is skipped, otherwise it was set to zsh during useradd
         arch-chroot /mnt chsh -s /bin/bash "${USERNAME}"
         info "User ${USERNAME}'s shell remains /bin/bash."

    fi
}

final_steps() {
    success "Arch Linux installation appears complete!"
    info "It is recommended to review the installed system before rebooting."
    info "You can use 'arch-chroot /mnt' to explore the installed system."
    warn "Remember to remove the installation medium before rebooting."

    # Unmount filesystems (handled by trap on exit, but can do explicitly here)
    # info "Unmounting filesystems..."
    # umount -R /mnt
    # [[ -n "$SWAP_PARTITION" ]] && swapoff "/dev/$SWAP_PARTITION"
    # success "Filesystems unmounted."


    echo -e "${C_GREEN}${C_BOLD}Installation finished. You can now type 'reboot' or 'shutdown now'.${C_OFF}"
    # Don't automatically reboot, let the user decide.
    # prompt "Press ENTER to reboot, or Ctrl+C to cancel." _
    # reboot
}

# --- Run the main function ---
main
