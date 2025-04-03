#!/bin/bash

# Arch Linux Installation Script - Reworked

# --- Configuration ---
SCRIPT_VERSION="2.3" # Incremented version for multilib enable fix
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
# Updated Timezone Defaults based on current location context
DEFAULT_REGION="America"
DEFAULT_CITY="Toronto" # Closest major city often used for timezones in Eastern Canada

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
        exit 1
    fi
    return $status
}


# Exit handler
trap 'cleanup' EXIT SIGHUP SIGINT SIGTERM
cleanup() {
    error "--- SCRIPT INTERRUPTED OR FAILED ---"
    info "Performing cleanup..."
    # Attempt to unmount everything in reverse order
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    # Deactivate swap if it was activated and variable exists
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null
    info "Cleanup finished. Check with 'lsblk' and 'mount'."
}

# --- Script Logic ---

main() {
    setup_environment
    check_boot_mode
    check_internet
    select_disk
    configure_partitioning
    configure_hostname_user
    select_kernel
    select_desktop_environment
    select_optional_packages
    configure_mirrors # This function is modified to ensure multilib is enabled correctly
    partition_and_format
    mount_filesystems
    install_base_system # This function calls pacstrap
    configure_installed_system
    install_bootloader
    install_oh_my_zsh
    final_steps
}

setup_environment() {
    set -e
    set -o pipefail
    info "Starting Arch Linux Installation Script v${SCRIPT_VERSION}"
    info "Current Time: $(date)"
    # Check if running as root
    if [[ "$EUID" -ne 0 ]]; then
        error "This script must be run as root."
        exit 1
    fi
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
    if timeout 5 ping -c 1 archlinux.org &> /dev/null; then
        success "Internet connection available."
    else
        # Attempt to bring up common interfaces (useful on some ISOs/boots)
        dhcpcd &> /dev/null || true # Try DHCP on default interfaces
        sleep 3 # Give DHCP a moment
         if timeout 5 ping -c 1 archlinux.org &> /dev/null; then
             success "Internet connection established after dhcpcd."
         else
             error "No internet connection detected. Please connect manually (e.g., iwctl, dhcpcd eth0) and restart the script."
            exit 1
        fi
    fi
}

select_disk() {
    info "Detecting available block devices..."
    mapfile -t devices < <(lsblk -dnpo name,type,size | awk '$2=="disk"{print $1" ("$3")"}')
    if [ ${#devices[@]} -eq 0 ]; then error "No disks found."; exit 1; fi

    echo "Available disks:"
    select device_choice in "${devices[@]}"; do
        if [[ -n "$device_choice" ]]; then
            TARGET_DISK=$(echo "$device_choice" | awk '{print $1}')
            TARGET_DISK_SIZE=$(echo "$device_choice" | awk '{print $2}')
            info "Selected disk: ${C_BOLD}${TARGET_DISK}${C_OFF} (${TARGET_DISK_SIZE})"
            break
        else error "Invalid selection."; fi
    done

    warn "ALL DATA ON ${C_BOLD}${TARGET_DISK}${C_OFF} WILL BE ERASED!"
    confirm "Are you absolutely sure?" || { info "Operation cancelled."; exit 0; }

    info "Wiping disk ${TARGET_DISK}..."
    sync
    sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || wipefs --all --force "${TARGET_DISK}" &>/dev/null || true
    sync
    check_status "Wiping disk ${TARGET_DISK}"
    partprobe "${TARGET_DISK}" &>/dev/null || true
    sleep 2
    success "Disk ${TARGET_DISK} wiped."
}

configure_partitioning() {
    info "Configuring partition layout for ${BOOT_MODE} mode."
    while true; do
        prompt "Enter Boot Partition size (e.g., 550M, 1G) [${MIN_BOOT_SIZE_MB}M+]: " BOOT_SIZE_INPUT
        BOOT_SIZE_INPUT=${BOOT_SIZE_INPUT:-550M}
        if [[ "$BOOT_SIZE_INPUT" =~ ^[0-9]+[MG]$ ]]; then
            local size_mb=$(echo "$BOOT_SIZE_INPUT" | sed 's/M$/;s/G$/\*1024/' | bc)
            if (( size_mb >= MIN_BOOT_SIZE_MB )); then
                BOOT_PART_SIZE=$BOOT_SIZE_INPUT; info "Boot size: ${BOOT_PART_SIZE}"; break
            else error "Boot size must be at least ${MIN_BOOT_SIZE_MB}M."; fi
        else error "Invalid format (e.g., 550M, 1G)."; fi
    done
    while true; do
        prompt "Enter Swap size (e.g., 4G, blank for NO swap): " SWAP_SIZE_INPUT
        if [[ -z "$SWAP_SIZE_INPUT" ]]; then SWAP_PART_SIZE=""; info "No swap partition."; break;
        elif [[ "$SWAP_SIZE_INPUT" =~ ^[0-9]+[MG]$ ]]; then SWAP_PART_SIZE=$SWAP_SIZE_INPUT; info "Swap size: ${SWAP_PART_SIZE}"; break;
        else error "Invalid format (e.g., 4G, 512M) or blank."; fi
    done
    if [[ "$TARGET_DISK" == *nvme* ]]; then PART_PREFIX="${TARGET_DISK}p"; else PART_PREFIX="${TARGET_DISK}"; fi
    info "Partition name prefix determined: ${PART_PREFIX}"
}

configure_hostname_user() {
    info "Configuring system identity..."
    while true; do prompt "Enter hostname: " HOSTNAME; [[ -n "$HOSTNAME" && ! "$HOSTNAME" =~ \ |\' ]] && break || error "Invalid hostname."; done
    while true; do prompt "Enter username: " USERNAME; [[ -n "$USERNAME" && ! "$USERNAME" =~ \ |\' ]] && break || error "Invalid username."; done
    info "Setting password for user '${USERNAME}'."
    while true; do
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Enter password: ")" USER_PASSWORD; echo
        read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Confirm password: ")" USER_PASSWORD_CONFIRM; echo
        if [[ -z "$USER_PASSWORD" ]]; then error "Password cannot be empty."; continue; fi
        if [[ "$USER_PASSWORD" == "$USER_PASSWORD_CONFIRM" ]]; then success "User password confirmed."; break; else error "Passwords do not match."; fi
    done
    info "Setting password for the root user."
    while true; do
         read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Enter root password: ")" ROOT_PASSWORD; echo
         read -s -p "$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Confirm root password: ")" ROOT_PASSWORD_CONFIRM; echo
        if [[ -z "$ROOT_PASSWORD" ]]; then error "Root password cannot be empty."; continue; fi
        if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then success "Root password confirmed."; break; else error "Root passwords do not match."; fi
    done
}

select_kernel() {
    info "Selecting Kernel..."
    kernels=("linux" "linux-lts" "linux-zen")
    echo "Available kernels:"
    select kernel_choice in "${kernels[@]}"; do [[ -n "$kernel_choice" ]] && { SELECTED_KERNEL=$kernel_choice; info "Selected kernel: ${C_BOLD}${SELECTED_KERNEL}${C_OFF}"; break; } || error "Invalid selection."; done
}

select_desktop_environment() {
    info "Selecting Desktop Environment or Server..."
    desktops=( "Server (No GUI)" "KDE Plasma" "GNOME" "XFCE" "LXQt" "MATE" )
    echo "Available environments:"
    select de_choice in "${desktops[@]}"; do [[ -n "$de_choice" ]] && { SELECTED_DE_NAME=$de_choice; SELECTED_DE_INDEX=$((REPLY - 1)); info "Selected: ${C_BOLD}${SELECTED_DE_NAME}${C_OFF}"; break; } || error "Invalid selection."; done
}

select_optional_packages() {
    info "Optional Packages..."
    INSTALL_STEAM=false; INSTALL_DISCORD=false
    confirm "Install Steam?" && { INSTALL_STEAM=true; info "Steam selected (requires multilib)."; }
    confirm "Install Discord?" && { INSTALL_DISCORD=true; info "Discord selected."; }
}

# --- !!! THIS FUNCTION HAS BEEN MODIFIED TO FIX MULTILIB ENABLEMENT !!! ---
configure_mirrors() {
    info "Configuring Pacman mirrors..."
    warn "This may take a few moments."
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup
    check_status "Backing up mirrorlist"

    info "Attempting to detect country..."
    # Increased timeout slightly for IP info service
    CURRENT_COUNTRY_CODE=$(curl -s --connect-timeout 7 ipinfo.io/country)
    if [[ -n "$CURRENT_COUNTRY_CODE" ]] && [[ ${#CURRENT_COUNTRY_CODE} -eq 2 ]]; then
         info "Detected country code: ${CURRENT_COUNTRY_CODE}. Using it for reflector."
         # Add neighbor country (US) for more options if detected country is CA
         [[ "$CURRENT_COUNTRY_CODE" == "CA" ]] && REFLECTOR_COUNTRIES="--country CA,US" || REFLECTOR_COUNTRIES="--country ${CURRENT_COUNTRY_CODE}"
    else
         warn "Could not detect country code. Using default (Canada, US)."
         REFLECTOR_COUNTRIES="--country CA,US" # Fallback countries
    fi

    info "Running reflector to find best mirrors..."
    reflector --verbose ${REFLECTOR_COUNTRIES} --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
    check_status "Running reflector"
    success "Mirrorlist updated."

    # Configure pacman.conf (Parallel Downloads, Color, Multilib)
    info "Configuring /etc/pacman.conf..."
    if confirm "Enable parallel downloads? (Recommended)"; then
         while true; do
            prompt "Parallel downloads (1-10, default: ${DEFAULT_PARALLEL_DL}): " PARALLEL_DL_COUNT
            PARALLEL_DL_COUNT=${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}
            if [[ "$PARALLEL_DL_COUNT" =~ ^[1-9]$|^10$ ]]; then
                info "Parallel downloads set to ${PARALLEL_DL_COUNT}."
                sed -i -E "s/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = ${PARALLEL_DL_COUNT}/" /etc/pacman.conf
                grep -q -E "^[[:space:]]*ParallelDownloads" /etc/pacman.conf || echo "ParallelDownloads = ${PARALLEL_DL_COUNT}" >> /etc/pacman.conf
                break
            else error "Please enter a number between 1 and 10."; fi
        done
    else info "Parallel downloads disabled."; sed -i -E 's/^[[:space:]]*ParallelDownloads/#&/' /etc/pacman.conf; fi

    info "Enabling Color in pacman..."
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(Color)/\1/' /etc/pacman.conf
    grep -q -E "^[[:space:]]*Color" /etc/pacman.conf || echo "Color" >> /etc/pacman.conf

    # --- Multilib Fix ---
    if $INSTALL_STEAM; then
        info "Enabling Multilib repository for Steam..."
        # Use sed to uncomment the block from '[multilib]' to the next 'Include' line
        # This handles potential blank lines or comments between them.
        # Check if [multilib] exists first
        if grep -q '\[multilib\]' /etc/pacman.conf; then
            # Use sed range to uncomment '#[multilib]' down to and including '#Include'
            # -E for extended regex, target commented lines in the range
            sed -i -e '/^#[[:space:]]*\[multilib\]/,/^#[[:space:]]*Include/ s/^#[[:space:]]*//' /etc/pacman.conf
            check_status "Enabling multilib repo using sed"
             # Verify if it worked
            if grep -q -E '^[[:space:]]*\[multilib\]' /etc/pacman.conf && grep -A 1 '\[multilib\]' /etc/pacman.conf | grep -q -E '^[[:space:]]*Include'; then
                success "Multilib repository appears enabled in /etc/pacman.conf."
            else
                error "Failed to reliably enable multilib in /etc/pacman.conf. Manual check needed."
                # Provide info for manual check
                warn "Please check '/etc/pacman.conf' manually and ensure the [multilib] section is uncommented:"
                warn "[multilib]"
                warn "Include = /etc/pacman.d/mirrorlist"
                confirm "Continue anyway (Steam installation might fail)?" || exit 1
            fi
        else
             error "Could not find '[multilib]' section in /etc/pacman.conf. Cannot enable."
             warn "Steam installation will likely fail. Consider editing pacman.conf manually."
             confirm "Continue anyway?" || exit 1
        fi
    else
        info "Multilib repository remains disabled (Steam not selected)."
    fi
    # --- End Multilib Fix ---

    # Refresh package databases *after* all pacman.conf modifications
    info "Synchronizing package databases (pacman -Syy)..."
    pacman -Syy
    check_status "pacman -Syy"
    success "Package databases synchronized."

     # Optional: Display multilib status again after sync
     if $INSTALL_STEAM; then
         info "Checking multilib package availability..."
         if pacman -Sl multilib &> /dev/null; then
             success "Multilib package list successfully loaded."
         else
             warn "Could not retrieve multilib package list after sync. Steam installation might still fail."
         fi
     fi
}

partition_and_format() {
    info "Partitioning ${TARGET_DISK} for ${BOOT_MODE}..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        info "Creating GPT partition table (UEFI)..."
        parted -s "${TARGET_DISK}" -- mklabel gpt \
            mkpart ESP fat32 1MiB "${BOOT_PART_SIZE}" set 1 esp on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning (GPT UEFI)"; BOOT_PARTITION="${PART_PREFIX}1"
        [[ -n "$SWAP_PART_SIZE" ]] && { SWAP_PARTITION="${PART_PREFIX}2"; ROOT_PARTITION="${PART_PREFIX}3"; } || { SWAP_PARTITION=""; ROOT_PARTITION="${PART_PREFIX}2"; }
    else # BIOS
        info "Creating MBR partition table (BIOS)..."
        sgdisk --zap-all "${TARGET_DISK}" &>/dev/null || true # Ensure GPT is gone
        parted -s "${TARGET_DISK}" -- mklabel msdos \
            mkpart primary ext4 1MiB "${BOOT_PART_SIZE}" set 1 boot on \
            $( [[ -n "$SWAP_PART_SIZE" ]] && echo "mkpart primary linux-swap ${BOOT_PART_SIZE} -$SWAP_PART_SIZE") \
            mkpart primary ext4 $( [[ -n "$SWAP_PART_SIZE" ]] && echo "-$SWAP_PART_SIZE" || echo "${BOOT_PART_SIZE}" ) 100%
        check_status "Partitioning (MBR BIOS)"; BOOT_PARTITION="${PART_PREFIX}1"
         [[ -n "$SWAP_PART_SIZE" ]] && { SWAP_PARTITION="${PART_PREFIX}2"; ROOT_PARTITION="${PART_PREFIX}3"; } || { SWAP_PARTITION=""; ROOT_PARTITION="${PART_PREFIX}2"; }
    fi
    partprobe "${TARGET_DISK}" &>/dev/null || true; sleep 2

    info "Disk layout planned:"; echo " Boot: ${BOOT_PARTITION}"; [[ -n "$SWAP_PARTITION" ]] && echo " Swap: ${SWAP_PARTITION}"; echo " Root: ${ROOT_PARTITION}"
    lsblk "${TARGET_DISK}"
    confirm "Proceed with formatting?" || { error "Formatting cancelled."; exit 1; }

    info "Formatting partitions..."
    # Format partitions using full paths stored in variables
    if [[ "$BOOT_MODE" == "UEFI" ]]; then mkfs.fat -F32 "${BOOT_PARTITION}"; check_status "Formatting EFI ${BOOT_PARTITION}";
    else mkfs.ext4 -F "${BOOT_PARTITION}"; check_status "Formatting Boot ${BOOT_PARTITION}"; fi
    [[ -n "$SWAP_PARTITION" ]] && { mkswap "${SWAP_PARTITION}"; check_status "Formatting Swap ${SWAP_PARTITION}"; }
    mkfs.ext4 -F "${ROOT_PARTITION}"; check_status "Formatting Root ${ROOT_PARTITION}"
    success "Partitions formatted."
}

mount_filesystems() {
    info "Mounting filesystems..."
    mount "${ROOT_PARTITION}" /mnt; check_status "Mounting root ${ROOT_PARTITION}"
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot; check_status "Mounting boot ${BOOT_PARTITION}"
    [[ -n "$SWAP_PARTITION" ]] && { swapon "${SWAP_PARTITION}"; check_status "Activating swap ${SWAP_PARTITION}"; }
    success "Filesystems mounted."; findmnt /mnt; findmnt /mnt/boot
}

install_base_system() {
    info "Installing base system packages (pacstrap)... This might take a while."
    CPU_VENDOR=$(grep -m 1 'vendor_id' /proc/cpuinfo | awk '{print $3}')
    MICROCODE_PACKAGE=""; if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then MICROCODE_PACKAGE="intel-ucode"; elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then MICROCODE_PACKAGE="amd-ucode"; fi
    [[ -n "$MICROCODE_PACKAGE" ]] && info "Adding microcode: ${MICROCODE_PACKAGE}."

    local base_pkgs=( "base" "$SELECTED_KERNEL" "linux-firmware" "base-devel" "grub" "networkmanager" "nano" "git" "wget" "curl" "reflector" "zsh" "btop" "fastfetch" "man-db" "man-pages" "texinfo" )
    [[ "$BOOT_MODE" == "UEFI" ]] && base_pkgs+=("efibootmgr")
    [[ -n "$MICROCODE_PACKAGE" ]] && base_pkgs+=("$MICROCODE_PACKAGE")

    local de_pkgs=(); ENABLE_DM=""
    case $SELECTED_DE_INDEX in
        0) de_pkgs+=("openssh");;
        1) de_pkgs+=( "plasma-desktop" "sddm" "konsole" "dolphin" "gwenview" "ark" "kcalc" "spectacle" "kate" "kscreen" "flatpak" "discover" "partitionmanager" "p7zip" "firefox" "plasma-nm" ); ENABLE_DM="sddm";;
        2) de_pkgs+=( "gnome" "gdm" "gnome-terminal" "nautilus" "gnome-text-editor" "gnome-control-center" "gnome-software" "eog" "file-roller" "flatpak" "firefox" "gnome-shell-extensions" "gnome-tweaks" ); ENABLE_DM="gdm";;
        3) de_pkgs+=( "xfce4" "xfce4-goodies" "lightdm" "lightdm-gtk-greeter" "xfce4-terminal" "thunar" "mousepad" "ristretto" "file-roller" "flatpak" "firefox" "network-manager-applet" ); ENABLE_DM="lightdm";;
        4) de_pkgs+=( "lxqt" "sddm" "qterminal" "pcmanfm-qt" "featherpad" "lximage-qt" "ark" "flatpak" "firefox" "network-manager-applet" ); ENABLE_DM="sddm";;
        5) de_pkgs+=( "mate" "mate-extra" "lightdm" "lightdm-gtk-greeter" "mate-terminal" "caja" "pluma" "eom" "engrampa" "flatpak" "firefox" "network-manager-applet" ); ENABLE_DM="lightdm";;
    esac

    local optional_pkgs=(); $INSTALL_STEAM && optional_pkgs+=("steam"); $INSTALL_DISCORD && optional_pkgs+=("discord")
    local all_pkgs=("${base_pkgs[@]}" "${de_pkgs[@]}" "${optional_pkgs[@]}")

    info "Packages to install: ${all_pkgs[*]}"
    confirm "Proceed with package installation?" || { error "Installation aborted."; exit 1; }

    pacstrap -K /mnt "${all_pkgs[@]}"
    check_status "Running pacstrap"
    success "Base system and selected packages installed."
}

configure_installed_system() {
    info "Configuring the installed system (chroot)..."
    info "Generating fstab..."
    genfstab -U /mnt >> /mnt/etc/fstab; check_status "Generating fstab"
    if grep -qE '/dev/(sd|nvme|vd)' /mnt/etc/fstab; then warn "fstab uses device names; UUIDs recommended."; fi
    success "fstab generated (/mnt/etc/fstab)."

    info "Copying Pacman configuration to chroot..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist; check_status "Copy mirrorlist"
    cp /etc/pacman.conf /mnt/etc/pacman.conf; check_status "Copy pacman.conf"

    # Create chroot script
    cat <<CHROOT_SCRIPT_EOF > /mnt/configure_chroot.sh
#!/bin/bash
set -e; set -o pipefail
# Inherited Variables: HOSTNAME, USERNAME, USER_PASSWORD, ROOT_PASSWORD, ENABLE_DM, INSTALL_STEAM, DEFAULT_REGION, DEFAULT_CITY, PARALLEL_DL_COUNT
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[0;34m'; C_BOLD='\033[1m'
info() { echo -e "\${C_BLUE}\${C_BOLD}[CHROOT INFO]\${C_OFF} \$1"; }; success() { echo -e "\${C_GREEN}\${C_BOLD}[CHROOT SUCCESS]\${C_OFF} \$1"; }; warn() { echo -e "\${C_YELLOW}\${C_BOLD}[WARN]\${C_OFF} \$1"; }; error() { echo -e "\${C_RED}\${C_BOLD}[CHROOT ERROR]\${C_OFF} \$1"; exit 1; }
check_status_chroot() { local s=\$?; if [ \$s -ne 0 ]; then error "Cmd failed (\$s): \$1"; fi; return \$s; }

info "Setting timezone (\${DEFAULT_REGION}/\${DEFAULT_CITY})..."
ln -sf "/usr/share/zoneinfo/\${DEFAULT_REGION}/\${DEFAULT_CITY}" /etc/localtime; check_status_chroot "Link timezone"
hwclock --systohc; check_status_chroot "Set HW clock"
success "Timezone set."

info "Configuring Locale (en_US.UTF-8)..."
echo "en_US.UTF-8 UTF-8" > /etc/locale.gen; locale-gen; check_status_chroot "Generate locale"
echo "LANG=en_US.UTF-8" > /etc/locale.conf; success "Locale set."

info "Setting hostname (\${HOSTNAME})..."
echo "\${HOSTNAME}" > /etc/hostname
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1 localhost
::1       localhost
127.0.1.1 \${HOSTNAME}.localdomain \${HOSTNAME}
EOF_HOSTS
success "Hostname set."

info "Setting root password..."; echo "root:\${ROOT_PASSWORD}" | chpasswd; check_status_chroot "Set root pw"; success "Root pw set."
info "Creating user \${USERNAME}..."; useradd -m -G wheel -s /bin/zsh "\${USERNAME}"; check_status_chroot "Create user"
echo "\${USERNAME}:\${USER_PASSWORD}" | chpasswd; check_status_chroot "Set user pw"; success "User \${USERNAME} created/pw set."

info "Configuring sudo for wheel group..."
sed -i -E 's/^#[[:space:]]*(%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL)/\1/' /etc/sudoers; check_status_chroot "Uncomment wheel sudo"
if ! grep -qE '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then warn "Wheel group sudo enabling might have failed. Check /etc/sudoers."; else success "Sudo configured."; fi

info "Ensuring Pacman config (ParallelDownloads=\${PARALLEL_DL_COUNT}, Color=On)..."
# This section might be redundant if pacman.conf copy was perfect, but ensures state
sed -i -E -e "s/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = \${PARALLEL_DL_COUNT}/" \
          -e "/^[[:space:]]*ParallelDownloads/!{ \$a\\ParallelDownloads = \${PARALLEL_DL_COUNT} }" \
          -e "s/^[[:space:]]*ParallelDownloads.*/ParallelDownloads = \${PARALLEL_DL_COUNT}/" \
          -e "s/^[[:space:]]*#[[:space:]]*(Color).*/\1/" \
          -e "/^[[:space:]]*Color/!{ \$a\\Color }" \
          /etc/pacman.conf
if [[ "\${INSTALL_STEAM}" == "true" ]]; then info "Ensuring Multilib is enabled in chroot..."; sed -i -e '/^#[[:space:]]*\[multilib\]/,/^#[[:space:]]*Include/ s/^#[[:space:]]*//' /etc/pacman.conf; fi
# Optional: Sync db again inside chroot if needed, but usually not required here
# pacman -Syy

info "Enabling NetworkManager service..."; systemctl enable NetworkManager; check_status_chroot "Enable NM"; success "NM enabled."
if [[ -n "\${ENABLE_DM}" ]]; then info "Enabling DM (\${ENABLE_DM})..."; systemctl enable "\${ENABLE_DM}.service"; check_status_chroot "Enable DM \${ENABLE_DM}"; success "DM enabled."; else info "No DM selected."; fi
if pacman -Qs openssh &>/dev/null; then info "Enabling sshd..."; systemctl enable sshd; check_status_chroot "Enable sshd"; success "sshd enabled."; fi

info "Updating initramfs (mkinitcpio)..."; mkinitcpio -P; check_status_chroot "mkinitcpio -P"; success "Initramfs updated."
success "Chroot configuration finished."
CHROOT_SCRIPT_EOF

    chmod +x /mnt/configure_chroot.sh; check_status "Chmod chroot script"
    info "Executing configuration script inside chroot..."; arch-chroot /mnt /configure_chroot.sh; check_status "Execute chroot script"
    rm /mnt/configure_chroot.sh
    success "System configuration complete."
}

install_bootloader() {
    info "Installing GRUB bootloader (${BOOT_MODE})..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck; check_status "grub-install UEFI";
    else arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"; check_status "grub-install BIOS ${TARGET_DISK}"; fi
    info "Generating GRUB config..."; arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg; check_status "grub-mkconfig"
    success "GRUB installed and configured."
}

install_oh_my_zsh() {
    if confirm "Install Oh My Zsh for '${USERNAME}' and root?"; then
        info "Installing Oh My Zsh..."
        local user_home="/home/${USERNAME}"
        # Install for root
        info "Installing for root..."
        if ! arch-chroot /mnt sh -c 'export RUNZSH=no CHSH=no; sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then
            warn "curl failed (root), trying wget..."; if ! arch-chroot /mnt sh -c 'export RUNZSH=no CHSH=no; sh -c "$(wget -qO- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then error "OMZ install failed (root)."; else success "OMZ installed (root/wget)."; arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc; fi
        else success "OMZ installed (root/curl)."; arch-chroot /mnt sed -i 's/^ZSH_THEME=.*/ZSH_THEME="robbyrussell"/' /root/.zshrc; fi
        # Install for user
        info "Installing for ${USERNAME}..."
        if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended; then
            warn "curl failed (${USERNAME}), trying wget..."; if ! arch-chroot /mnt sudo -u "${USERNAME}" env HOME="${user_home}" RUNZSH=no CHSH=no sh -c "$(wget -qO- https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended'; then error "OMZ install failed (${USERNAME})."; else success "OMZ installed (${USERNAME}/wget)."; arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"; warn "Install 'powerline-fonts' for agnoster theme."; fi
        else success "OMZ installed (${USERNAME}/curl)."; arch-chroot /mnt sed -i "s/^ZSH_THEME=.*/ZSH_THEME=\"agnoster\"/" "${user_home}/.zshrc"; warn "Install 'powerline-fonts' for agnoster theme."; fi
    else
        info "Oh My Zsh skipped. Setting user shell to /bin/bash."
        arch-chroot /mnt chsh -s /bin/bash "${USERNAME}"; check_status "Set ${USERNAME} shell to bash"
    fi
}

final_steps() {
    success "Arch Linux installation appears complete!"
    info "Review the system with 'arch-chroot /mnt' before rebooting."
    warn "Remove the installation medium before rebooting."
    info "Attempting final unmount..."; sync
    umount -R /mnt &>/dev/null || umount -R -l /mnt &>/dev/null || true
    [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]] && swapoff "${SWAP_PARTITION}" &>/dev/null || true
    success "Attempted unmount. Check with 'lsblk'."
    echo -e "${C_GREEN}${C_BOLD}\n----------------------------------------------------\n Installation finished at $(date).\n Type 'reboot' or 'shutdown now'.\n----------------------------------------------------${C_OFF}"
}

# --- Run Script ---
main
exit 0
