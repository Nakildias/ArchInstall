#!/bin/bash

# --- Disk & Filesystem Operations ---

select_disk() {
    update_status "Step 1/12: Disk Selection"
    print_header "DISK SELECTION"
    print_action "Detecting available block devices..."
    
    # Use lsblk to get NAME, TYPE, SIZE, and ensure it's a disk (exclude rom, loop)
    mapfile -t devices < <(lsblk -dnpo name,type,size | awk '$2=="disk"{print $1" ("$3")"}')

    if [ ${#devices[@]} -eq 0 ]; then
        error "No disks found. Ensure drives are properly connected."
        exit 1
    fi

    local choice=""
    ask_selection "Select Installation Disk:" choice 1 "${devices[@]}"
    
    # Extract just the name (e.g., /dev/sda)
    TARGET_DISK=$(echo "$choice" | awk '{print $1}')
    TARGET_DISK_SIZE=$(echo "$choice" | awk '{print $2}' | tr -d '()')
    
    print_action "Selected disk: ${TARGET_DISK} (${TARGET_DISK_SIZE})"

    warn "ALL DATA ON ${TARGET_DISK} WILL BE ERASED!"
    confirm "Are you absolutely sure you want to partition ${TARGET_DISK}?" || { print_action "Operation cancelled by user."; exit 0; }

    # Wiping is done thoroughly in partition_and_format before sgdisk runs
    print_action "Disk ${TARGET_DISK} selected. Wiping will occur before partitioning."
    sleep 1
}

cleanup_disk_state() {
    local disk="$1"
    print_action "Performing aggressive disk cleanup on ${disk}..."

    # 1. Turn off all swap (to release any swap partitions on this disk)
    # 1. Turn off all swap (to release any swap partitions on this disk)
    exec_silent swapoff -a || true

    # 2. Force close any cryptsetup containers (e.g. leftovers from failed installs)
    # We attempt common names.
    exec_silent cryptsetup close cryptroot || true

    # 3. Targeted dmsetup remove for THIS disk only
    # SECURITY: Do NOT use remove_all as it could affect secondary drives
    local disk_basename
    disk_basename=$(basename "${disk}")
    
    # Find device mapper entries that reference this disk and remove them
    for dm_name in $(lsblk -ln -o NAME "${disk}" 2>/dev/null | grep -v "^${disk_basename}$"); do
        if [[ -e "/dev/mapper/${dm_name}" ]]; then
            exec_silent dmsetup remove --retry "${dm_name}" || true
        fi
    done
    
    # Also try to remove cryptroot if it exists and is on this disk
    if cryptsetup status cryptroot &>/dev/null; then
        local crypt_backing
        crypt_backing=$(cryptsetup status cryptroot 2>/dev/null | grep "device:" | awk '{print $2}')
        if [[ "$crypt_backing" == *"${disk_basename}"* ]]; then
            exec_silent cryptsetup close cryptroot || true
        fi
    fi

    # 4. Wipefs again just to be sure
    exec_silent wipefs --all --force "${disk}" || true

    print_subitem "Disk cleanup complete."
}

select_swap_choice() {
    update_status "Step 10/12: Swap Configuration"
    print_header "SWAP CONFIGURATION"
    
    if [[ "$USE_CONFIG" == "true" && -n "${SWAP_TYPE:-}" ]]; then
        print_action "Using Swap Type from config: $SWAP_TYPE"

        # If partition, check size too
        if [[ "$SWAP_TYPE" == "Partition" && -n "${SWAP_PART_SIZE:-}" ]]; then
             print_subitem "Using Swap Partition Size from config: $SWAP_PART_SIZE"
        fi
        return
    fi

    local swap_options=(
        "ZRAM      | RAM Compression (Fastest performance)"
        "Partition | Physical Disk (Supports Hibernation)"
        "None      | No Swap"
    )

    local choice=""
    ask_selection "Select Swap Configuration:" choice 1 "${swap_options[@]}"
    
    # Extract
    SWAP_TYPE=$(echo "$choice" | awk '{print $1}')
    print_action "Selected Swap Type: ${SWAP_TYPE}"

    # Handle configuration based on choice
    SWAP_PART_SIZE="" # Reset default

    if [[ "$SWAP_TYPE" == "Partition" ]]; then
        while true; do
            prompt "Enter Swap Partition size (e.g., 4G, 8G): " SWAP_INPUT
            if [[ "$SWAP_INPUT" =~ ^[0-9]+[MG]$ ]]; then
                SWAP_PART_SIZE=$SWAP_INPUT
                print_subitem "Swap partition size set to: ${SWAP_PART_SIZE}"
                break
            else
                error "Invalid format. Use number followed by M or G (e.g., 4G, 8G)."
            fi
        done
    elif [[ "$SWAP_TYPE" == "ZRAM" ]]; then
        print_subitem "ZRAM will be configured automatically (Size: min(RAM, 8GB), Algo: zstd)."
    else
        print_subitem "No swap will be configured."
    fi
}

select_filesystem() {
    update_status "Step 10/12: Filesystem Selection"
    print_header "FILESYSTEM SELECTION"
    
    if [[ "$USE_CONFIG" == "true" && -n "${SELECTED_FS:-}" ]]; then
        print_action "Using Filesystem from config: $SELECTED_FS"
        return
    fi

    local filesystems=(
        "ext4  | The Standard (Stable, Reliable)"
        "btrfs | Modern (Snapshots, Compression)"
        "xfs   | High Performance (Fast I/O)"
    )

    local choice=""
    ask_selection "Select Filesystem for Root:" choice 1 "${filesystems[@]}"
    
    SELECTED_FS=$(echo "$choice" | awk '{print $1}')
    print_action "Selected Filesystem: ${SELECTED_FS}"
}

ask_encryption() {
    update_status "Step 10/12: Encryption"
    print_header "ENCRYPTION SETUP"
    
    # MODIFIED: Check config for enablement choice
    if [[ "$USE_CONFIG" == "true" && -n "${ENABLE_ENCRYPTION:-}" ]]; then
        if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
             print_action "Encryption enabled via config."
             get_password "Disk Encryption (LUKS)" "LUKS_PASSWORD"
             return
        else
             print_action "Encryption disabled via config."
             LUKS_PASSWORD=""
             return
        fi
    fi

    ENABLE_ENCRYPTION="false"
    LUKS_PASSWORD=""

    print_context "Encryption protects your data if your device is stolen."
    print_context "Note: You will need to type a password every time you boot."

    if confirm "Encrypt the installation (LUKS)?"; then
        ENABLE_ENCRYPTION="true"
        get_password "Disk Encryption (LUKS)" "LUKS_PASSWORD"
        print_subitem "Encryption enabled. The root partition will be encrypted."
    else
        print_subitem "Encryption skipped. Standard plain partitions will be used."
    fi
}

configure_partitioning() {
    print_action "Configuring partition layout sizes."

    # MODIFIED: Check config for boot size
    if [[ "$USE_CONFIG" == "true" && -n "${BOOT_PART_SIZE:-}" ]]; then
         BOOT_PART_SIZE=$BOOT_PART_SIZE
         print_subitem "Using Boot Partition size from config: ${BOOT_PART_SIZE}"
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
                    print_subitem "Boot partition size set to: ${BOOT_PART_SIZE}"
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
    print_subitem "Partition name prefix determined: ${PART_PREFIX}"
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
    print_action "Wiping and partitioning ${TARGET_DISK}..."

    # AGGRESSIVE CLEANUP for re-installations
    cleanup_disk_state "${TARGET_DISK}"

    run_quiet "Clearing Filesystem Signatures" wipefs --all --force "${TARGET_DISK}"
    exec_silent sgdisk --zap-all "${TARGET_DISK}"

    # Create partitions (Standard layout)
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        exec_silent sgdisk -n ${BOOT_PART_NUM}:0:+${BOOT_PART_SIZE} -t ${BOOT_PART_NUM}:EF00 -c ${BOOT_PART_NUM}:"EFISystem" "${TARGET_DISK}"
    else
        exec_silent sgdisk -n ${BOOT_PART_NUM}:0:+${BOOT_PART_SIZE} -t ${BOOT_PART_NUM}:8300 -c ${BOOT_PART_NUM}:"BIOSBoot" "${TARGET_DISK}"
        exec_silent sgdisk -n ${BIOS_BOOT_PART_NUM}:0:+1MiB -t ${BIOS_BOOT_PART_NUM}:EF02 -c ${BIOS_BOOT_PART_NUM}:"BIOSBootPartition" "${TARGET_DISK}"
    fi

    if [[ -n "$SWAP_PARTITION" ]]; then
        exec_silent sgdisk -n ${SWAP_PART_NUM}:0:+${SWAP_PART_SIZE} -t ${SWAP_PART_NUM}:8200 -c ${SWAP_PART_NUM}:"LinuxSwap" "${TARGET_DISK}"
    fi

    # Root gets remaining space
    exec_silent sgdisk -n ${ROOT_PART_NUM}:0:0 -t ${ROOT_PART_NUM}:8300 -c ${ROOT_PART_NUM}:"LinuxRoot" "${TARGET_DISK}"

    exec_silent partprobe "${TARGET_DISK}" || true
    sleep 3

    # --- ENCRYPTION LOGIC ---
    TARGET_ROOT_DEVICE="${ROOT_PARTITION}" # Default to raw partition
    MAPPER_NAME="cryptroot"

    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        print_action "Encrypting Root Partition ${ROOT_PARTITION}..."

        # Format partition with LUKS (password passed via stdin, NOT as argument)
        # Using printf instead of echo -n for better portability
        print_subitem "Formatting LUKS..."
        printf '%s' "${LUKS_PASSWORD}" | cryptsetup -q luksFormat "${ROOT_PARTITION}" - >> "$LOG_FILE" 2>&1
        check_status "LUKS Format"

        # Open the encrypted container
        print_subitem "Opening LUKS container..."
        printf '%s' "${LUKS_PASSWORD}" | cryptsetup open "${ROOT_PARTITION}" "${MAPPER_NAME}" - >> "$LOG_FILE" 2>&1
        check_status "Opening LUKS container"

        # Point the formatter to the MAPPER device, not the raw partition
        TARGET_ROOT_DEVICE="/dev/mapper/${MAPPER_NAME}"
        print_subitem "Encrypted container opened at ${TARGET_ROOT_DEVICE}"
    fi

    # --- FORMATTING (Dynamic Filesystem) ---
    print_action "Formatting Root (${TARGET_ROOT_DEVICE}) as ${SELECTED_FS}..."

    case "$SELECTED_FS" in
        ext4)
            print_action "Formatting ext4..."
            mkfs.ext4 -F "${TARGET_ROOT_DEVICE}"
            ;;
        btrfs)
            print_action "Formatting btrfs..."
            mkfs.btrfs -f "${TARGET_ROOT_DEVICE}"
            ;;
        xfs)
            print_action "Formatting xfs..."
            mkfs.xfs -f "${TARGET_ROOT_DEVICE}"
            ;;
    esac
    check_status "Formatting Root as ${SELECTED_FS}"

    # Format Boot
    if [[ "$BOOT_MODE" == "UEFI" ]]; then
        print_action "Formatting Boot (FAT32)..."
        mkfs.fat -F32 "${BOOT_PARTITION}"
    else
        print_action "Formatting Boot (ext4)..."
        mkfs.ext4 -F "${BOOT_PARTITION}"
    fi

    # Format Swap
    if [[ -n "$SWAP_PARTITION" ]]; then
        print_action "Formatting Swap..."
        mkswap "${SWAP_PARTITION}"
    fi
}

mount_filesystems() {
    print_action "Mounting filesystems..."

    local MOUNT_SOURCE="${ROOT_PARTITION}"
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        MOUNT_SOURCE="/dev/mapper/cryptroot"
    fi

    # --- BTRFS LOGIC ---
    if [[ "$SELECTED_FS" == "btrfs" ]]; then
        print_subitem "Detected Btrfs. Creating extended subvolume layout..."

        # 1. Mount the raw root temporarily
        mount "${MOUNT_SOURCE}" /mnt

        # 2. Create subvolumes
        # Standard
        btrfs subvolume create /mnt/@ >/dev/null
        btrfs subvolume create /mnt/@home >/dev/null
        
        # Extended Layout
        btrfs subvolume create /mnt/@snapshots >/dev/null  # For Snapper
        btrfs subvolume create /mnt/@var_log >/dev/null    # For system logs (excluded from snapshots)

        # Attributes (NoCoW for logs)
        chattr +C /mnt/@var_log

        # Unmount raw root
        umount /mnt

        # Mount Subvolumes
        MOUNT_OPTS="compress=zstd,subvol="
        
        # Root (@) -> /
        mount -o "compress=zstd,subvol=@" "${MOUNT_SOURCE}" /mnt
        
        # Home (@home) -> /home
        mkdir -p /mnt/home
        mount -o "compress=zstd,subvol=@home" "${MOUNT_SOURCE}" /mnt/home
        
        # Snapshots (@snapshots) -> /.snapshots
        mkdir -p /mnt/.snapshots
        mount -o "compress=zstd,subvol=@snapshots" "${MOUNT_SOURCE}" /mnt/.snapshots
        
        # Var Log (@var_log) -> /var/log
        mkdir -p /mnt/var/log
        mount -o "compress=zstd,subvol=@var_log" "${MOUNT_SOURCE}" /mnt/var/log

        print_subitem "Btrfs extended subvolumes configured (@, @home, @snapshots, @var_log)."
    else
        # --- STANDARD LOGIC ---
        print_subitem "Mounting Root (${MOUNT_SOURCE}) on /mnt"
        mount "${MOUNT_SOURCE}" /mnt
    fi
    check_status "Mounting root"

    # --- BOOT PARTITION ---
    print_action "Mounting Boot partition..."
    mount --mkdir "${BOOT_PARTITION}" /mnt/boot

    # --- SWAP ---
    if [[ -n "$SWAP_PARTITION" ]]; then
        swapon "${SWAP_PARTITION}"
    fi
}
