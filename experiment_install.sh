#!/bin/bash
# Arch Linux Installation Script by Nakildias
# Version 2.0 - Improved with BIOS/UEFI support, more DEs, better error handling

# --- Configuration ---
set -e # Exit immediately if a command exits with a non-zero status.
# set -u # Treat unset variables as an error when substituting.
# set -o pipefail # Causes a pipeline to return the exit status of the last command in the pipe that returned a non-zero status.

# --- Colors ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# --- Helper Functions ---
error_exit() {
    echo -e "${RED}Error: $1${NC}" >&2
    # Consider unmounting partitions here before exiting if needed
    # umount -R /mnt 2>/dev/null || true
    exit 1
}

info() {
    echo -e "${BLUE}INFO: $1${NC}"
}

success() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}

warning() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}

prompt() {
    echo -en "${CYAN}$1${NC}"
}

check_command() {
    if ! command -v $1 &> /dev/null; then
        error_exit "$1 command not found. Please ensure base-devel is installed or you are in the Arch ISO."
    fi
}

# --- Pre-Checks ---
check_command fdisk
check_command parted
check_command mkfs.fat
check_command mkswap
check_command mkfs.ext4
check_command mount
check_command pacman
check_command pacstrap
check_command genfstab
check_command arch-chroot
check_command grub-install
check_command grub-mkconfig

# --- Script Start ---
info "Welcome to Arch Install Script v2.0 by Nakildias"

# --- Determine Boot Mode (UEFI or Legacy BIOS) ---
BOOT_MODE="BIOS"
if [ -d "/sys/firmware/efi/efivars" ]; then
    BOOT_MODE="UEFI"
    success "UEFI firmware detected."
else
    warning "No UEFI firmware detected. Assuming Legacy BIOS mode."
    # Optional: Add strict check to ensure it's *definitely* BIOS or ask user?
fi
read -p "Press ENTER to continue..."

# --- Disk Selection ---
info "Retrieving list of available block devices..."
mapfile -t devices < <(lsblk -dno NAME,SIZE,TYPE | awk '$3 == "disk" {print "/dev/"$1 " ("$2")"}')

if [ ${#devices[@]} -eq 0 ]; then
    error_exit "No disk devices found."
fi

echo -e "${BLUE}Available disks:${NC}"
select device_selection in "${devices[@]}"; do
    if [[ -n "$device_selection" ]]; then
        disk_path=$(echo "$device_selection" | awk '{print $1}')
        disk=$(basename "$disk_path")
        success "You selected $disk_path"
        break
    else
        echo -e "${RED}Invalid selection. Please choose a number from the list.${NC}"
    fi
done

# --- Confirmation ---
warning "This script will ERASE ALL DATA on ${disk_path}."
prompt "Are you absolutely sure you want to continue? (yes/no): "
read -r confirmation
if [[ "${confirmation,,}" != "yes" ]]; then
    info "Operation canceled by user."
    exit 0
fi

# --- Wipe Existing Signatures and Partition Table ---
info "Wiping existing filesystem signatures and partition table on /dev/$disk..."
wipefs -a "/dev/$disk" || error_exit "Failed to wipe signatures on /dev/$disk."
sgdisk --zap-all "/dev/$disk" || error_exit "Failed to zap partition table on /dev/$disk." # Works for both GPT/MBR
sync

# --- Partition Size Input ---
# Boot Partition
while true; do
    prompt "Enter Boot Partition Size (e.g., 512M, 1G - Recommended: 512M-1G for UEFI, >=200M for BIOS): " BootSize
    if [[ $BootSize =~ ^[0-9]+[MG]$ ]]; then
        # Basic sanity check - at least 100M
        size_val=$(echo $BootSize | sed 's/[MG]//')
        size_unit=$(echo $BootSize | sed 's/[0-9]//')
        if [[ "$size_unit" == "G" ]]; then size_val=$((size_val * 1024)); fi # Convert G to M for comparison
        if (( size_val >= 100 )); then
             success "Boot size set to: $BootSize"
             break
        else
             echo -e "${RED}Boot size must be at least 100M.${NC}"
        fi
    else
        echo -e "${RED}Invalid format. Please enter size like '512M' or '1G'.${NC}"
    fi
done

# Swap Partition (Optional)
SWAP_ENABLED=false
while true; do
    prompt "Create a Swap Partition? (Recommended based on RAM/Hibernation needs) (y/n, default: y): " create_swap
    create_swap=${create_swap:-y}
    case "${create_swap,,}" in
        y|yes)
            SWAP_ENABLED=true
            while true; do
                prompt "Enter Swap Size (e.g., 4G, 8G - size depends on RAM and hibernation use): " SwapSize
                if [[ $SwapSize =~ ^[0-9]+[MG]$ ]]; then
                    success "Swap size set to: $SwapSize"
                    break
                else
                    echo -e "${RED}Invalid format. Please enter size like '4G' or '512M'.${NC}"
                fi
            done
            break
            ;;
        n|no)
            SWAP_ENABLED=false
            info "Swap partition will not be created."
            break
            ;;
        *)
            echo -e "${RED}Invalid input. Please enter 'y' or 'n'.${NC}" ;;
    esac
done

# --- Partitioning the Disk ---
info "Partitioning /dev/$disk for $BOOT_MODE mode..."
# Using sgdisk for reliability and scriptability

# sgdisk codes: 8300 Linux filesystem, 8200 Linux swap, EF00 EFI System Partition, 8304 Linux /boot (often used for BIOS boot)
PART_NUM_BOOT=1
PART_NUM_SWAP=$([ "$SWAP_ENABLED" == "true" ] && echo 2 || echo "")
PART_NUM_ROOT=$([ "$SWAP_ENABLED" == "true" ] && echo 3 || echo 2)

if [ "$BOOT_MODE" == "UEFI" ]; then
    info "Creating GPT partition table."
    sgdisk --zap-all /dev/"$disk" || error_exit "Failed to zap /dev/$disk"
    # Partition 1: EFI System Partition (ESP)
    sgdisk -n ${PART_NUM_BOOT}:0:+"$BootSize" -t ${PART_NUM_BOOT}:EF00 -c ${PART_NUM_BOOT}:"EFI System Partition" /dev/"$disk" || error_exit "Failed to create EFI partition."
    # Partition 2: Swap (optional)
    if $SWAP_ENABLED; then
        sgdisk -n ${PART_NUM_SWAP}:0:+"$SwapSize" -t ${PART_NUM_SWAP}:8200 -c ${PART_NUM_SWAP}:"Linux swap" /dev/"$disk" || error_exit "Failed to create swap partition."
    fi
    # Partition 3 (or 2): Root
    sgdisk -n ${PART_NUM_ROOT}:0:0 -t ${PART_NUM_ROOT}:8300 -c ${PART_NUM_ROOT}:"Linux root" /dev/"$disk" || error_exit "Failed to create root partition."
else # BIOS Mode
    info "Creating MBR (msdos) partition table."
    parted -s /dev/"$disk" mklabel msdos || error_exit "Failed to create MBR label on /dev/$disk"
    # Partition 1: Boot Partition (can be ext4)
    parted -s /dev/"$disk" mkpart primary ext4 1MiB "${BootSize}" || error_exit "Failed to create BIOS boot partition."
    parted -s /dev/"$disk" set ${PART_NUM_BOOT} boot on || error_exit "Failed to set boot flag on partition 1."
    # Partition 2: Swap (optional)
    if $SWAP_ENABLED; then
        local swap_start=$BootSize # Approximate start, parted handles exact offsets
        parted -s /dev/"$disk" mkpart primary linux-swap "$swap_start" "$(echo $swap_start+$SwapSize | sed 's/M/MiB/g; s/G/GiB/g')" || error_exit "Failed to create swap partition."
        local root_start=$(echo $swap_start+$SwapSize | sed 's/M/MiB/g; s/G/GiB/g') # Approximate start
    else
        local root_start=$BootSize # Approximate start
    fi
    # Partition 3 (or 2): Root
    parted -s /dev/"$disk" mkpart primary ext4 "$root_start" 100% || error_exit "Failed to create root partition."
fi

success "Partitioning complete."
info "Waiting 5 seconds for kernel to recognize new partitions..."
sleep 5
info "Current disk layout:"
lsblk "/dev/$disk"
fdisk -l "/dev/$disk" # Use fdisk for a familiar view

# --- Assign Partition Variables ---
# Need to handle different device naming conventions (e.g., /dev/sda1 vs /dev/nvme0n1p1)
if [[ "$disk" == nvme* ]]; then
    PART_PREFIX="p"
else
    PART_PREFIX=""
fi
Partition_Boot="/dev/${disk}${PART_PREFIX}${PART_NUM_BOOT}"
Partition_Swap=$($SWAP_ENABLED && echo "/dev/${disk}${PART_PREFIX}${PART_NUM_SWAP}" || echo "")
Partition_Root="/dev/${disk}${PART_PREFIX}${PART_NUM_ROOT}"

info "Device nodes assigned:"
echo -e "  Boot: ${Partition_Boot}"
[ "$SWAP_ENABLED" == "true" ] && echo -e "  Swap: ${Partition_Swap}"
echo -e "  Root: ${Partition_Root}"
prompt "Press ENTER if everything seems OK."
read -r

# --- Formatting Partitions ---
info "Formatting partitions..."
if [ "$BOOT_MODE" == "UEFI" ]; then
    mkfs.fat -F 32 "$Partition_Boot" || error_exit "Failed to format EFI partition $Partition_Boot"
else # BIOS
    mkfs.ext4 -L BOOT "$Partition_Boot" || error_exit "Failed to format Boot partition $Partition_Boot"
fi

if $SWAP_ENABLED; then
    mkswap "$Partition_Swap" || error_exit "Failed to create swap on $Partition_Swap"
fi

mkfs.ext4 -L ROOT "$Partition_Root" || error_exit "Failed to format Root partition $Partition_Root"
success "Formatting Done."

# --- Mounting Partitions ---
info "Mounting partitions..."
mount "$Partition_Root" /mnt || error_exit "Failed to mount root partition $Partition_Root to /mnt"
mount --mkdir "$Partition_Boot" /mnt/boot || error_exit "Failed to mount boot partition $Partition_Boot to /mnt/boot"

if $SWAP_ENABLED; then
    swapon "$Partition_Swap" || error_exit "Failed to enable swap on $Partition_Swap"
fi
success "Mounting Completed."
info "Current mounts:"
lsblk /dev/$disk

# --- Base Installation ---
info "Updating pacman mirrors (using reflector)..."
reflector --latest 10 --protocol https --sort rate --save /etc/pacman.d/mirrorlist || warning "Reflector failed, using existing mirrorlist."

info "Updating archlinux-keyring..."
pacman -Sy --noconfirm archlinux-keyring || error_exit "Failed to update archlinux-keyring."

# Parallel Downloads Configuration
enable_parallel="n"
parallel_value=5
while true; do
    prompt "Enable Parallel Downloads in pacman? (Speeds up downloads) (y/n, default: y): " Parallel
    Parallel=${Parallel:-y}
    case "${Parallel,,}" in
        y|yes)
            enable_parallel="y"
            while true; do
                prompt "How many download threads? (1-10, default: 5): " Parallel_Value
                Parallel_Value=${Parallel_Value:-5}
                if [[ "$Parallel_Value" =~ ^[0-9]+$ ]] && ((Parallel_Value >= 1 && Parallel_Value <= 10)); then
                    success "Using $Parallel_Value parallel downloads."
                    # Apply to current environment temporarily for pacstrap
                    sudo sed -i "s/^#\(ParallelDownloads\s*=\s*\).*/\1$Parallel_Value/" /etc/pacman.conf
                    parallel_value=$Parallel_Value # Store for later chroot application
                    break
                else
                    echo -e "${RED}Error: Please enter a number between 1 and 10.${NC}"
                fi
            done
            break
            ;;
        n|no)
            info "Parallel Downloads disabled."
            # Ensure it's commented out in the host
            sudo sed -i "s/^\(ParallelDownloads\s*=\s*\)/#\1/" /etc/pacman.conf
            break
            ;;
        *) echo -e "${RED}Invalid input. Please enter 'y' or 'n'.${NC}" ;;
    esac
done


# Kernel Selection
while true; do
    prompt "Choose your kernel (linux=stable, linux-lts=longterm, linux-zen=performance, default=linux): " kernel
    kernel=${kernel:-linux}
    case $kernel in
        linux|linux-lts|linux-zen)
            success "Selected kernel: $kernel"
            break
            ;;
        *) echo -e "${RED}Invalid choice: '$kernel'. Please try again.${NC}" ;;
    esac
done
kernel_headers="${kernel}-headers" # Add headers for DKMS modules etc.

# Microcode
CPU_VENDOR=$(grep vendor_id /proc/cpuinfo | head -n 1 | awk '{print $3}')
microcode_pkg=""
if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
    microcode_pkg="intel-ucode"
    info "Intel CPU detected. Will install intel-ucode."
elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
    microcode_pkg="amd-ucode"
    info "AMD CPU detected. Will install amd-ucode."
else
    warning "Could not determine CPU vendor for microcode."
fi

# --- Desktop Environment / Window Manager Selection ---
info "Choose your Desktop Environment or Window Manager:"
echo "   0) Server / Base CLI Only ${GREEN}[Minimal]${NC}"
echo "   1) KDE Plasma (Wayland/X11) ${GREEN}[Recommended Full]${NC}"
echo "   2) GNOME (Wayland default) ${GREEN}[Recommended Full]${NC}"
echo "   3) XFCE4 (X11) ${GREEN}[Recommended Lightweight]${NC}"
echo "   4) Cinnamon (X11) ${YELLOW}[Community]${NC}"
echo "   5) Budgie (X11) ${YELLOW}[Community]${NC}"
echo "   6) LXQt (X11) ${YELLOW}[Lightweight]${NC}"
echo "   7) i3 WM (Tiling X11) ${MAGENTA}[Advanced/Minimal]${NC}"
echo "   8) Sway WM (Tiling Wayland) ${MAGENTA}[Advanced/Minimal]${NC}"
# Add more here later (Mate, LXDE etc.)

while true; do
    prompt "Enter selection [0-8] (default=0): " de_choice
    de_choice=${de_choice:-0}
    if [[ "$de_choice" =~ ^[0-8]$ ]]; then
        success "You selected option $de_choice."
        break
    else
        echo -e "${RED}Invalid input. Please enter a number between 0 and 8.${NC}"
    fi
done

# Define Core Packages
base_pkgs="base $kernel $kernel_headers linux-firmware base-devel"
common_utils="nano git wget curl reflector fastfetch btop openssh man-db man-pages texinfo"
network_pkgs="networkmanager"
bootloader_pkgs="grub"
if [ "$BOOT_MODE" == "UEFI" ]; then
    bootloader_pkgs="$bootloader_pkgs efibootmgr"
fi
if [[ -n "$microcode_pkg" ]]; then
    base_pkgs="$base_pkgs $microcode_pkg"
fi

# Define DE/WM specific packages
de_pkgs=""
display_manager=""
display_manager_service=""
case $de_choice in
    0) # Server / CLI
        info "Installing Base CLI system."
        de_pkgs=""
        ;;
    1) # KDE Plasma
        info "Selecting KDE Plasma packages."
        de_pkgs="plasma-meta konsole dolphin kate gwenview spectacle partitionmanager kcalc flatpak packagekit-qt5 ark p7zip"
        # plasma-meta includes: plasma-desktop, sddm, plasma-wayland-session, plasma-nm, discover etc.
        display_manager="sddm"
        display_manager_service="sddm.service"
        ;;
    2) # GNOME
        info "Selecting GNOME packages."
        de_pkgs="gnome gnome-terminal nautilus gnome-text-editor gnome-software flatpak loupe gnome-control-center" # gnome includes gdm, gnome-shell, wayland session, settings etc.
        # gnome-software needs packagekit: gnome-software packagekit
        de_pkgs="$de_pkgs packagekit"
        display_manager="gdm"
        display_manager_service="gdm.service"
        ;;
    3) # XFCE
        info "Selecting XFCE4 packages."
        de_pkgs="xfce4 xfce4-goodies xfce4-terminal thunar mousepad parole ristretto xarchiver"
        de_pkgs="$de_pkgs lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings network-manager-applet" # Need DM and NM applet
        display_manager="lightdm"
        display_manager_service="lightdm.service"
        ;;
    4) # Cinnamon
        info "Selecting Cinnamon packages."
        de_pkgs="cinnamon gnome-terminal nemo gnome-screenshot metacity" # Metacity needed for theme settings
        de_pkgs="$de_pkgs lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings network-manager-applet"
        display_manager="lightdm"
        display_manager_service="lightdm.service"
        ;;
    5) # Budgie
        info "Selecting Budgie Desktop packages."
        de_pkgs="budgie-desktop gnome-terminal nautilus gnome-control-center" # Uses many GNOME components
        de_pkgs="$de_pkgs lightdm lightdm-gtk-greeter lightdm-gtk-greeter-settings network-manager-applet"
        display_manager="lightdm"
        display_manager_service="lightdm.service"
        ;;
    6) # LXQt
        info "Selecting LXQt packages."
        de_pkgs="lxqt qterminal pcmanfm-qt featherpad lximage-qt ark"
        de_pkgs="$de_pkgs sddm network-manager-applet" # Using SDDM as a Qt-based DM
        display_manager="sddm"
        display_manager_service="sddm.service"
        ;;
    7) # i3 WM
        info "Selecting i3 Window Manager packages."
        de_pkgs="i3-wm i3status i3lock dmenu terminator rofi feh picom lxappearance" # Base i3 + essentials
        de_pkgs="$de_pkgs lightdm lightdm-gtk-greeter network-manager-applet" # Optional: Use a DM or startx
        display_manager="lightdm" # Optional DM
        display_manager_service="lightdm.service" # Optional DM service
        warning "i3 requires manual configuration after install (e.g., in ~/.config/i3/config)."
        ;;
    8) # Sway WM
        info "Selecting Sway Window Manager packages."
        de_pkgs="sway swaybg swayidle swaylock waybar foot wofi mako grim slurp" # Base Sway + essentials (Wayland native)
        de_pkgs="$de_pkgs seatd polkit # network-manager-applet needs X/tray, maybe nmtui/nmcli?" # Needs seatd for session/permissions
        display_manager="" # Typically started from TTY with 'sway' command after login
        display_manager_service=""
        warning "Sway requires manual configuration and login from TTY (or configure a Wayland login manager like greetd)."
        warning "Ensure video drivers support Wayland (Mesa generally does)."
        ;;
esac

# Add common GUI apps if not a server install
if [ "$de_choice" != "0" ]; then
    de_pkgs="$de_pkgs firefox pipewire pipewire-pulse pipewire-jack wireplumber" # Browser and Audio stack
    if [ "$BOOT_MODE" == "UEFI" ]; then
        # Fonts needed for GRUB UEFI menu graphics
        de_pkgs="$de_pkgs gnu-free-fonts"
    fi
fi

# Combine all package lists
all_packages="$base_pkgs $common_utils $network_pkgs $bootloader_pkgs $de_pkgs"

# --- Pacstrap ---
info "Installing base system and packages onto /mnt..."
echo "Packages: $all_packages"
if ! pacstrap -K /mnt $all_packages; then
    error_exit "Pacstrap failed. Check network connection and pacman errors."
fi
success "Pacstrap completed successfully."

# --- Generate fstab ---
info "Generating fstab..."
genfstab -U /mnt >> /mnt/etc/fstab
# Verify fstab (optional but recommended)
info "Generated /mnt/etc/fstab:"
cat /mnt/etc/fstab
success "fstab generated."

# --- Chroot into the New System and Configure ---
info "Entering chroot environment..."

# Timezone Setup
# Could be improved with tzselect or listing areas/cities
info "Setting up Time Zone."
default_region="America"
default_city="New_York" # Adjusted default
prompt "Enter Region (e.g., Europe, Asia, default=${default_region}): " Region
Region=${Region:-$default_region}
prompt "Enter City within $Region (e.g., London, Tokyo, default=${default_city}): " City
City=${City:-$default_city}
zone_path="/usr/share/zoneinfo/$Region/$City"

if [ ! -f "/mnt$zone_path" ]; then
    warning "Timezone '$Region/$City' not found. Falling back to UTC."
    arch-chroot /mnt ln -sf /usr/share/zoneinfo/UTC /etc/localtime
else
    arch-chroot /mnt ln -sf "$zone_path" /etc/localtime
    success "Timezone set to $Region/$City."
fi
arch-chroot /mnt hwclock --systohc # Set hardware clock from system time

# Locale Setup
info "Setting up Locale."
default_locale="en_US.UTF-8"
prompt "Enter desired locale (default=${default_locale}): " system_locale
system_locale=${system_locale:-$default_locale}
info "Configuring locale: $system_locale"
# Uncomment the locale in locale.gen
arch-chroot /mnt sed -i "s/^#\(${system_locale}\)/\1/" /etc/locale.gen || warning "Could not uncomment locale ${system_locale} in /etc/locale.gen (maybe already uncommented or invalid?)."
# Set LANG in locale.conf
echo "LANG=${system_locale}" | arch-chroot /mnt tee /etc/locale.conf > /dev/null
# Generate locales
arch-chroot /mnt locale-gen || error_exit "locale-gen failed."
success "Locale configured and generated."

# Hostname Setup
while true; do
    prompt "Enter hostname (e.g., archlinux): " hostname
    if [[ -n "$hostname" ]]; then
        info "Setting hostname to '$hostname'."
        echo "$hostname" | arch-chroot /mnt tee /etc/hostname > /dev/null
        # Add to hosts file
        echo "127.0.0.1 localhost" | arch-chroot /mnt tee /etc/hosts > /dev/null
        echo "::1       localhost" | arch-chroot /mnt tee -a /etc/hosts > /dev/null
        echo "127.0.1.1 ${hostname}.localdomain ${hostname}" | arch-chroot /mnt tee -a /etc/hosts > /dev/null
        success "Hostname set."
        break
    else
        echo -e "${RED}Hostname cannot be empty.${NC}"
    fi
done


# Root Password
info "Set the root password."
until arch-chroot /mnt passwd; do
    warning "Password setting failed or mismatch. Please try again."
done
success "Root password set."

# User Creation
info "Creating a regular user account."
while true; do
    prompt "Enter username for the new user: " username
    if [[ -n "$username" ]]; then
        if ! id "$username" &>/dev/null; then # Check if user already exists in host - less likely needed in chroot but good practice
            arch-chroot /mnt useradd -m -G wheel "$username" || error_exit "Failed to create user $username."
            success "User '$username' created."
            break
        else
            echo -e "${RED}User '$username' already exists.${NC}"
        fi
    else
        echo -e "${RED}Username cannot be empty.${NC}"
    fi
done

info "Set the password for user '$username'."
until arch-chroot /mnt passwd "$username"; do
    warning "Password setting failed or mismatch. Please try again."
done
success "Password set for user '$username'."

info "Granting sudo privileges to user '$username' (via wheel group)."
# Uncomment '%wheel ALL=(ALL:ALL) ALL' in sudoers
arch-chroot /mnt sed -i '/^# %wheel ALL=(ALL:ALL) ALL/s/^# //' /etc/sudoers
# Alternative (safer): Add a drop-in file
# echo "%wheel ALL=(ALL:ALL) ALL" | arch-chroot /mnt tee /etc/sudoers.d/10-wheel-group > /dev/null
success "Sudo privileges enabled for the 'wheel' group."


# Apply Parallel Downloads in chroot system
if [ "$enable_parallel" == "y" ]; then
    info "Applying ParallelDownloads=$parallel_value to /etc/pacman.conf inside chroot."
    arch-chroot /mnt sed -i "s/^#\(ParallelDownloads\s*=\s*\).*/\1$parallel_value/" /etc/pacman.conf
    arch-chroot /mnt sed -i "s/^\(ParallelDownloads\s*=\s*\).*/\1$parallel_value/" /etc/pacman.conf # Ensure it's set even if not commented
fi

# Enable Essential Services
info "Enabling NetworkManager service..."
arch-chroot /mnt systemctl enable NetworkManager.service || warning "Failed to enable NetworkManager service."

# Enable Display Manager (if selected)
if [[ -n "$display_manager_service" ]]; then
    info "Enabling Display Manager service: $display_manager_service..."
    arch-chroot /mnt systemctl enable "$display_manager_service" || warning "Failed to enable $display_manager_service."
else
    info "No Display Manager selected/required for this setup."
fi

# Enable other services as needed (e.g., sshd)
while true; do
    prompt "Enable SSH server (sshd) service? (y/n, default: n): " enable_ssh
    enable_ssh=${enable_ssh:-n}
    case "${enable_ssh,,}" in
        y|yes)
            info "Enabling sshd service..."
            arch-chroot /mnt systemctl enable sshd.service || warning "Failed to enable sshd service."
            break
            ;;
        n|no)
            info "SSHD service will not be enabled."
            break
            ;;
        *) echo -e "${RED}Invalid input. Please enter 'y' or 'n'.${NC}" ;;
    esac
done

# --- Oh-My-Bash Installation (Optional) ---
while true; do
    prompt "Install Oh My Bash for user '$username' and root? (y/n, default: n): " install_omb
    install_omb=${install_omb:-n}
    case "${install_omb,,}" in
        y|yes)
            info "Installing Oh My Bash..."
            # Install for root first
            if arch-chroot /mnt bash -c 'export RUNZSH="no"; export CHSH="no"; bash <(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh) --unattended'; then
                 success "Oh My Bash installed for root."
                 # Install for user
                 if arch-chroot /mnt sudo -u "$username" bash -c 'export RUNZSH="no"; export CHSH="no"; bash <(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh) --unattended'; then
                    success "Oh My Bash installed for user $username."
                 else
                    warning "Failed to install Oh My Bash for user $username."
                 fi
            else
                 warning "Failed to install Oh My Bash for root."
            fi
            # Note: Custom theme setup omitted for simplicity, user can configure later.
            break
            ;;
        n|no)
            info "Oh My Bash will not be installed."
            break
            ;;
        *) echo -e "${RED}Invalid input. Please enter 'y' or 'n'.${NC}" ;;
    esac
done

# --- Bootloader Installation (GRUB) ---
info "Installing GRUB bootloader..."
if [ "$BOOT_MODE" == "UEFI" ]; then
    info "Installing GRUB for UEFI on $Partition_Boot..."
    if ! arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck; then
        error_exit "GRUB UEFI installation failed."
    fi
else # BIOS
    info "Installing GRUB for BIOS/MBR on /dev/$disk..."
    if ! arch-chroot /mnt grub-install --target=i386-pc --recheck /dev/"$disk"; then
         error_exit "GRUB BIOS installation failed."
    fi
fi

info "Generating GRUB configuration file..."
if ! arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg; then
    error_exit "grub-mkconfig failed."
fi
success "GRUB installed and configured."

# --- Finishing Up ---
info "Exiting chroot environment."
# Unmount partitions (optional, happens on shutdown/reboot anyway)
# info "Unmounting partitions..."
# umount -R /mnt || warning "Failed to unmount partitions cleanly."

success "Arch Linux installation is complete!"
info "You can now reboot your system."
prompt "Press ENTER to reboot, or Ctrl+C to cancel and return to the live environment."
read -r
reboot
