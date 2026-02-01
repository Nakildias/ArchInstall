#!/bin/bash

# --- Configuration ---
SCRIPT_VERSION="1.4"

# --- Colors ---
C_OFF='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;34m'
C_BOLD='\033[1m'

# --- Logging Helpers ---
info() { echo -e "${C_BLUE}[INFO]${C_OFF} $1"; }
warn() { echo -e "${C_YELLOW}[WARN]${C_OFF} $1"; }
error() { echo -e "${C_RED}[ERROR]${C_OFF} $1"; }
success() { echo -e "${C_GREEN}[SUCCESS]${C_OFF} $1"; }

ask() {
    # $1 = Prompt text, $2 = Variable name to read into
    echo -n -e "${C_YELLOW}${1}${C_OFF}"
    read "$2"
}

# --- Helper Functions ---

check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "Please run as root."
        exit 1
    fi
}

check_dependencies() {
    local deps=("lsblk" "mount" "umount" "arch-chroot" "efibootmgr" "grub-install" "genfstab")
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &> /dev/null; then
            error "Missing dependency: $dep"
            exit 1
        fi
    done
}

detect_boot_mode() {
    if [ -d "/sys/firmware/efi/efivars" ]; then
        BOOT_MODE="UEFI"
        info "System is booted in ${C_BOLD}UEFI${C_OFF} mode."
    else
        BOOT_MODE="BIOS"
        info "System is booted in ${C_BOLD}Legacy BIOS${C_OFF} mode."
    fi
}

select_disk() {
    echo "------------------------------------------------"
    lsblk -d -p -n -o NAME,SIZE,MODEL,TYPE | grep "disk"
    echo "------------------------------------------------"

    while true; do
        ask "Enter the drive to check (e.g. /dev/sda): " TARGET_DISK
        if [[ -b "$TARGET_DISK" ]]; then
            info "Selected disk: $TARGET_DISK"
            break
        else
            error "Invalid device. Please try again."
        fi
    done
}

identify_partitions() {
    info "Scanning partitions on $TARGET_DISK..."

    # 1. Guess ROOT (Largest PARTITION) - Flattened output
    GUESS_ROOT=$(lsblk -n -l -b -p -o NAME,SIZE,TYPE,FSTYPE "$TARGET_DISK" | awk '$3=="part"' | grep -v "swap" | sort -k2 -rn | head -n1 | awk '{print $1}')

    # 2. Guess EFI/Boot (Smallest PARTITION) - Flattened output
    GUESS_EFI=""
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
         GUESS_EFI=$(lsblk -n -l -b -p -o NAME,SIZE,TYPE "$TARGET_DISK" | awk '$3=="part"' | sort -k2 -n | head -n1 | awk '{print $1}')
    fi

    echo ""
    echo -e "${C_BOLD}Partition Identification:${C_OFF}"

    # --- CONFIRM ROOT ---
    ask "  Is ${C_GREEN}${GUESS_ROOT}${C_OFF} your ROOT (/) partition? [Y/n]: " confirm_root
    if [[ "$confirm_root" =~ ^[nN] ]]; then
        lsblk -p "$TARGET_DISK"
        ask "  Enter your ROOT partition (e.g. /dev/sda2): " PART_ROOT
    else
        PART_ROOT="$GUESS_ROOT"
    fi

    # --- CONFIRM EFI (Only if UEFI) ---
    PART_EFI=""
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        ask "  Is ${C_GREEN}${GUESS_EFI}${C_OFF} your EFI (/boot) partition? [Y/n]: " confirm_efi
        if [[ "$confirm_efi" =~ ^[nN] ]]; then
            lsblk -p "$TARGET_DISK"
            ask "  Enter your EFI partition (e.g. /dev/sda1): " PART_EFI
        else
            PART_EFI="$GUESS_EFI"
        fi
    fi

    # Sanitize input
    PART_ROOT=$(echo "$PART_ROOT" | xargs)
    PART_EFI=$(echo "$PART_EFI" | xargs)

    if [[ -z "$PART_ROOT" ]]; then error "Root partition not defined."; exit 1; fi
    if [[ "$BOOT_MODE" == "UEFI" && -z "$PART_EFI" ]]; then error "EFI partition not defined."; exit 1; fi
}

check_integrity() {
    info "Mounting partitions to check status..."

    mkdir -p /mnt/repair
    
    # Detect filesystem type first
    local fs_type
    fs_type=$(lsblk -n -o FSTYPE "$PART_ROOT" | head -n1)

    if [[ "$fs_type" == "btrfs" ]]; then
        # Mount the @ subvolume for Btrfs
        info "Detected Btrfs filesystem, mounting @ subvolume..."
        mount -o subvol=@ "$PART_ROOT" /mnt/repair
    else
        mount "$PART_ROOT" /mnt/repair
    fi
    
    if [[ "$BOOT_MODE" == "UEFI" ]]; then mount "$PART_EFI" /mnt/repair/boot; fi

    # --- 1. BOOTLOADER FILES ---
    STATUS_GRUB="Missing"
    if [ -f "/mnt/repair/boot/grub/grub.cfg" ]; then STATUS_GRUB="Found"; fi

    STATUS_SD="Missing"
    if [ -f "/mnt/repair/boot/loader/loader.conf" ]; then STATUS_SD="Found"; fi

    STATUS_EFI_BIN="N/A"
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        if find /mnt/repair/boot -name "*.efi" | grep -q .; then STATUS_EFI_BIN="Found"; else STATUS_EFI_BIN="Missing"; fi
    fi

    # --- 2. FSTAB UUID CHECK ---
    IS_FSTAB_BROKEN="false"
    FSTAB_FILE="/mnt/repair/etc/fstab"
    REAL_UUID=$(lsblk -n -o UUID "$PART_ROOT")

    if [ ! -f "$FSTAB_FILE" ]; then
        STATUS_FSTAB="Missing"
        IS_FSTAB_BROKEN="true"
    else
        # Extract UUID for "/" mount point
        CONFIGURED_UUID=$(grep -E "[[:space:]]/[[:space:]]" "$FSTAB_FILE" | grep -o "UUID=[^ ]*" | cut -d= -f2)

        if [[ -z "$CONFIGURED_UUID" ]]; then
            STATUS_FSTAB="Unknown"
            IS_FSTAB_BROKEN="true"
        elif [[ "$REAL_UUID" == "$CONFIGURED_UUID" ]]; then
            STATUS_FSTAB="Match (OK)"
        else
            STATUS_FSTAB="MISMATCH!"
            IS_FSTAB_BROKEN="true"
        fi
    fi

    # --- 3. KERNEL & INITRAMFS CHECKS ---
    IS_KERNEL_BROKEN="false"
    STATUS_KERNEL="OK"
    if [[ ! -s "/mnt/repair/boot/vmlinuz-linux" ]]; then
        STATUS_KERNEL="Missing/Empty!"
        IS_KERNEL_BROKEN="true"
    fi

    STATUS_INITRAMFS="OK"
    if [[ ! -s "/mnt/repair/boot/initramfs-linux.img" ]]; then
        STATUS_INITRAMFS="Missing/Empty!"
        IS_KERNEL_BROKEN="true"
    fi

    # --- 4. PACMAN LOCK CHECK ---
    IS_PACMAN_BROKEN="false"
    if [[ -f "/mnt/repair/var/lib/pacman/db.lck" ]]; then
        IS_PACMAN_BROKEN="true"
        STATUS_PACMAN="LOCKED (Update Failed?)"
    else
        STATUS_PACMAN="OK"
    fi

    # --- 5. MICROCODE CHECK ---
    STATUS_UCODE="OK"
    CPU_VENDOR=$(grep -m1 "vendor_id" /proc/cpuinfo | awk '{print $3}')
    if [[ "$CPU_VENDOR" == "GenuineIntel" ]]; then
        if [[ ! -f "/mnt/repair/boot/intel-ucode.img" ]]; then
            STATUS_UCODE="Missing (Intel)"
            IS_KERNEL_BROKEN="true"
        fi
    elif [[ "$CPU_VENDOR" == "AuthenticAMD" ]]; then
        if [[ ! -f "/mnt/repair/boot/amd-ucode.img" ]]; then
            STATUS_UCODE="Missing (AMD)"
            IS_KERNEL_BROKEN="true"
        fi
    fi

    # Report
    echo ""
    echo "--- Diagnosis Report ---"
    echo "  Boot Mode:      $BOOT_MODE"
    echo "  GRUB Config:    $STATUS_GRUB"
    echo "  Systemd-boot:   $STATUS_SD"
    [[ "$BOOT_MODE" == "UEFI" ]] && echo "  EFI Binaries:   $STATUS_EFI_BIN"

    if [[ "$IS_FSTAB_BROKEN" == "true" ]]; then echo -e "  Fstab UUID:     ${C_RED}$STATUS_FSTAB${C_OFF}"; else echo -e "  Fstab UUID:     ${C_GREEN}$STATUS_FSTAB${C_OFF}"; fi
    if [[ "$IS_KERNEL_BROKEN" == "true" ]]; then echo -e "  Kernel Image:   ${C_RED}$STATUS_KERNEL${C_OFF}"; else echo -e "  Kernel Image:   ${C_GREEN}$STATUS_KERNEL${C_OFF}"; fi
    if [[ "$IS_KERNEL_BROKEN" == "true" && "$STATUS_INITRAMFS" != "OK" ]]; then echo -e "  Initramfs:      ${C_RED}$STATUS_INITRAMFS${C_OFF}"; fi
    if [[ "$IS_PACMAN_BROKEN" == "true" ]]; then echo -e "  Pacman State:   ${C_RED}$STATUS_PACMAN${C_OFF}"; else echo -e "  Pacman State:   ${C_GREEN}$STATUS_PACMAN${C_OFF}"; fi
    if [[ "$STATUS_UCODE" != "OK" ]]; then echo -e "  Microcode:      ${C_YELLOW}$STATUS_UCODE${C_OFF}"; fi
    echo "------------------------"

    IS_BOOT_BROKEN="false"
    if [[ "$STATUS_GRUB" == "Missing" && "$STATUS_SD" == "Missing" ]]; then IS_BOOT_BROKEN="true"; fi
    if [[ "$BOOT_MODE" == "UEFI" && "$STATUS_EFI_BIN" == "Missing" ]]; then IS_BOOT_BROKEN="true"; fi

    # Unmount
    umount -R /mnt/repair
}

repair_system() {
    # 1. Ask about Bootloader
    echo ""
    echo "Select Repair Action:"
    echo "  1) Reinstall GRUB + Fix All (Recommended)"
    echo "  2) Reinstall systemd-boot + Fix All"
    echo "  3) Fix Configs Only (Fstab/Initramfs) - No Bootloader"
    echo "  4) Cancel"
    ask "Choice [1-4]: " BL_CHOICE

    case "$BL_CHOICE" in
        1) INSTALL_BL="grub" ;;
        2)
            if [[ "$BOOT_MODE" == "BIOS" ]]; then error "systemd-boot is not supported in BIOS mode."; return; fi
            INSTALL_BL="systemd-boot"
            ;;
        3) INSTALL_BL="none" ;;
        *) info "Repair cancelled."; return ;;
    esac

    info "Starting repair process..."
    
    # Detect filesystem type for proper mounting
    local fs_type
    fs_type=$(lsblk -n -o FSTYPE "$PART_ROOT" | head -n1)
    
    if [[ "$fs_type" == "btrfs" ]]; then
        mount -o subvol=@ "$PART_ROOT" /mnt/repair
    else
        mount "$PART_ROOT" /mnt/repair
    fi
    
    [[ "$BOOT_MODE" == "UEFI" ]] && mount "$PART_EFI" /mnt/repair/boot

    # --- CLEANUP CONFLICTING BOOTLOADERS ---
    if [[ "$INSTALL_BL" == "grub" ]]; then
        if [[ -d "/mnt/repair/boot/loader" ]]; then
            warn "Found conflicting systemd-boot files. Removing them..."
            rm -rf /mnt/repair/boot/loader
            rm -rf /mnt/repair/boot/EFI/systemd
            # Optional: remove fallback fallback entry if exists
            rm -f /mnt/repair/boot/EFI/BOOT/BOOTX64.EFI
            success "Removed systemd-boot artifacts."
        fi
    elif [[ "$INSTALL_BL" == "systemd-boot" ]]; then
        if [[ -d "/mnt/repair/boot/grub" ]]; then
            warn "Found conflicting GRUB files. Removing them..."
            rm -rf /mnt/repair/boot/grub
            rm -rf /mnt/repair/boot/EFI/ARCH
            rm -rf /mnt/repair/boot/EFI/grub
            success "Removed GRUB artifacts."
        fi
    fi

    # --- REPAIR 1: REMOVE PACMAN LOCK ---
    if [[ "$IS_PACMAN_BROKEN" == "true" ]]; then
        info "Removing stale pacman lock file..."
        rm -f /mnt/repair/var/lib/pacman/db.lck
    fi

    # --- REPAIR 2: FSTAB ---
    if [[ "$IS_FSTAB_BROKEN" == "true" || "$INSTALL_BL" != "none" ]]; then
        info "Regenerating /etc/fstab..."
        if [ -f /mnt/repair/etc/fstab ]; then cp /mnt/repair/etc/fstab "/mnt/repair/etc/fstab.bak.$(date +%s)"; fi
        genfstab -U /mnt/repair > /mnt/repair/etc/fstab
        success "Fstab updated."
    fi

    # --- REPAIR 3: CHROOT ACTIONS ---
    cat <<EOF > /mnt/repair/repair_exec.sh
#!/bin/bash
source /etc/profile
C_GREEN='\033[0;32m'
C_OFF='\033[0m'

# Fix Kernel/Microcode
if [[ "$IS_KERNEL_BROKEN" == "true" || "$STATUS_UCODE" != "OK" ]]; then
    echo "Reinstalling Kernel and Microcode..."
    pacman -Sy --noconfirm linux linux-firmware intel-ucode amd-ucode
    echo "Regenerating initramfs..."
    mkinitcpio -P
fi

if [[ "$INSTALL_BL" == "grub" ]]; then
    echo "Installing GRUB..."
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
    else
        grub-install --target=i386-pc --recheck "$TARGET_DISK"
    fi
    echo "Generating GRUB Config..."
    grub-mkconfig -o /boot/grub/grub.cfg

elif [[ "$INSTALL_BL" == "systemd-boot" ]]; then
    echo "Installing systemd-boot..."
    bootctl install

    if [ ! -f /boot/loader/loader.conf ]; then
        echo "default arch.conf" > /boot/loader/loader.conf
        echo "timeout 3" >> /boot/loader/loader.conf
    fi

    KERNEL_IMG=\$(ls /boot/vmlinuz-linux* | head -n1 | xargs basename)
    INITRD_IMG=\$(ls /boot/initramfs-linux.img | head -n1 | xargs basename)
    ROOT_UUID=\$(findmnt / -n -o UUID)

    echo "Creating entry for \$KERNEL_IMG..."
    cat <<ENTRY > /boot/loader/entries/arch.conf
title Arch Linux (Repaired)
linux /\$KERNEL_IMG
initrd /\$INITRD_IMG
options root=UUID=\$ROOT_UUID rw
ENTRY
fi
EOF
    chmod +x /mnt/repair/repair_exec.sh

    info "Executing repair inside system..."
    arch-chroot /mnt/repair /repair_exec.sh

    rm /mnt/repair/repair_exec.sh
}

# --- Main Logic ---

check_root
check_dependencies
detect_boot_mode
select_disk
identify_partitions
check_integrity

echo ""
if [[ "$IS_BOOT_BROKEN" == "true" || "$IS_FSTAB_BROKEN" == "true" || "$IS_KERNEL_BROKEN" == "true" || "$IS_PACMAN_BROKEN" == "true" ]]; then
    warn "Issues detected!"
    ask "Do you want to attempt an AUTOMATIC REPAIR? [y/N]: " CONFIRM
else
    success "System looks structurally okay."
    ask "Do you want to reinstall/repair anyway? [y/N]: " CONFIRM
fi

if [[ "$CONFIRM" =~ ^[yY] ]]; then
    repair_system
    umount -R /mnt/repair &>/dev/null
    success "Done! You can now reboot."
else
    info "Exiting without making changes."
    umount -R /mnt/repair &>/dev/null
fi
