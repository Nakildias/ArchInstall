#!/bin/bash

# --- Main Installation Phases ---

configure_mirrors() {
    print_action "Configuring Package Mirrors..."
    
    # Backup
    cp /etc/pacman.d/mirrorlist /etc/pacman.d/mirrorlist.backup

    if [[ "$USE_LOCAL_MIRROR" == "true" ]]; then
        echo "Server = ${LOCAL_MIRROR_URL}/archlinux/\$repo/os/\$arch" > /etc/pacman.d/mirrorlist
        print_subitem "Use Local: ${LOCAL_MIRROR_URL}"
    elif [ "$ARCH_WEBSITE_REACHABLE" = "true" ]; then
        print_subitem "Detecting location..."
        # We can run this quietly
        CURRENT_COUNTRY_CODE=$(curl -fsSL --connect-timeout 5 https://ipinfo.io/country || echo "")
        
        if [[ -n "$CURRENT_COUNTRY_CODE" ]] && [[ ${#CURRENT_COUNTRY_CODE} -eq 2 ]]; then
             REFLECTOR_COUNTRIES="--country ${CURRENT_COUNTRY_CODE}"
             print_subitem "Detected: ${CURRENT_COUNTRY_CODE}"
        else
             REFLECTOR_COUNTRIES="--country Canada"
             print_subitem "Defaulting: Canada"
        fi
        
        run_quiet "Reflecting mirrors (Best 20, HTTPS)" reflector ${REFLECTOR_COUNTRIES} --protocol https --latest 20 --sort rate --save /etc/pacman.d/mirrorlist
    else
        warn "Arch website unreachable. Using default mirrorlist."
    fi

    # Parallel & Color
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(ParallelDownloads).*/\1 = '"${PARALLEL_DL_COUNT:-5}"'/' /etc/pacman.conf
    sed -i -E 's/^[[:space:]]*#[[:space:]]*(Color)/\1/' /etc/pacman.conf
    if ! grep -q "ParallelDownloads" /etc/pacman.conf; then echo "ParallelDownloads = ${PARALLEL_DL_COUNT:-5}" >> /etc/pacman.conf; fi
    if ! grep -q "Color" /etc/pacman.conf; then echo "Color" >> /etc/pacman.conf; fi

    # Multilib
    if [ "${INSTALL_STEAM:-false}" = "true" ] || [ "${ENABLE_MULTILIB:-false}" = "true" ]; then
        sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
        print_subitem "Multilib enabled."
    fi

    # Sync
    run_quiet "Synchronizing databases" pacman -Syy --noconfirm
    run_quiet "Updating keyring" pacman -Sy --noconfirm archlinux-keyring
}

install_base_system() {
    print_header "BASE SYSTEM INSTALLATION"
    
    if ! mountpoint -q /mnt; then
        error "Target /mnt is not mounted."
        return 1
    fi

    local base_pkgs=(
        "base" "base-devel" "$SELECTED_KERNEL" "linux-firmware"
        "grub" "gptfdisk" "networkmanager" "nano" "vim" "git" "wget" "curl"
        "cryptsetup" "btrfs-progs" "xfsprogs" "reflector" "btop"
        "man-db" "man-pages" "texinfo" "efibootmgr"
        "zsh" "zsh-completions" "zsh-autosuggestions" "zsh-syntax-highlighting"
        "lsd" "fastfetch" "fzf" "tmux" "neovim"
        "ttf-firacode-nerd" "ttf-jetbrains-mono-nerd"
    )

    # Microcode
    local cpu_vendor
    cpu_vendor=$(grep -m1 "^vendor_id" /proc/cpuinfo | awk '{print $3}')
    if [[ "$cpu_vendor" == "GenuineIntel" ]]; then base_pkgs+=("intel-ucode"); fi
    if [[ "$cpu_vendor" == "AuthenticAMD" ]]; then base_pkgs+=("amd-ucode"); fi

    # ZRAM
    [[ "$SWAP_TYPE" == "ZRAM" ]] && base_pkgs+=("zram-generator")

    # GPU
    if [[ "$INSTALL_NVIDIA" == "true" ]]; then
        base_pkgs+=("nvidia-dkms" "nvidia-utils" "nvidia-settings")
        [[ "$ENABLE_MULTILIB" == "true" ]] && base_pkgs+=("lib32-nvidia-utils")
    fi
    if [[ "$INSTALL_VMWARE" == "true" ]]; then base_pkgs+=("open-vm-tools" "xf86-video-vmware" "gtkmm3"); fi
    if [[ "$INSTALL_QEMU" == "true" ]]; then base_pkgs+=("qemu-guest-agent" "spice-vdagent" "xf86-video-qxl"); fi
    
    # 1. Source the DE config FIRST (so we know if it's a Server install)
    local de_pkgs=()
    local dm_service=""
    local session_name=""

    if [[ -n "${SELECTED_DE_CONFIG:-}" && -f "$SELECTED_DE_CONFIG" ]]; then
        source "$SELECTED_DE_CONFIG"
        de_pkgs=("${DE_PKGS[@]}")
        dm_service="$DE_DM_SERVICE"
        session_name="$DE_SESSION_NAME"
    else
        de_pkgs=("openssh")
    fi
     
    # Persist DM choice for chroot script usage
    echo "DM_SERVICE='$dm_service'" > /tmp/arch_install_dm_choice
    echo "TARGET_SESSION_NAME='$session_name'" >> /tmp/arch_install_dm_choice
    echo "AUTO_LOGIN_USER='$AUTO_LOGIN_USER'" >> /tmp/arch_install_dm_choice

    # 2. NOW check the DE_NAME (from sourced config) or SELECTED_DE_NAME
    # This must happen AFTER sourcing so we know the actual profile
    local common_gui_pkgs=()
    if [[ "${DE_NAME:-}" == "Server" || "${SELECTED_DE_NAME:-}" == "Server" ]]; then
        # Server only needs SSH
        common_gui_pkgs=("openssh")
    else
        # Desktop installs get the full GUI stack
        common_gui_pkgs=("pipewire-alsa" "pipewire-pulse" "alsa-utils" "flatpak" "firefox" "openssh")
    fi

    # Extras
    local optional_pkgs=()
    $INSTALL_STEAM   && optional_pkgs+=("steam")
    $INSTALL_DISCORD && optional_pkgs+=("discord")
    $INSTALL_UFW     && optional_pkgs+=("ufw")

    # 3. Combine all package lists
    local all_pkgs=("${base_pkgs[@]}" "${de_pkgs[@]}" "${optional_pkgs[@]}" "${common_gui_pkgs[@]}")

    print_subitem "Packages requested: ${#all_pkgs[@]}"
    log_to_file "PKGLIST: ${all_pkgs[*]}"

    # --- Real Statistics Calculation ---
    print_action "Resolving dependencies..."
    
    # Get package count from URL list (one URL per package including deps)
    local pkg_count=0
    local pkg_list
    if pkg_list=$(pacman -Sp --needed "${all_pkgs[@]}" 2>/dev/null); then
        pkg_count=$(echo "$pkg_list" | wc -l)
    fi
    
    if [[ $pkg_count -gt 0 ]]; then
        print_subitem "Total Packages (with dependencies): ${C_BOLD}${pkg_count}${C_OFF}"
    else
        print_subitem "Packages requested: ${#all_pkgs[@]}"
    fi

    # Run Pacstrap
    # run_quiet wraps run_with_retry if we want, or just call pacstrap directly.
    # pacstrap is robust but long.
    run_quiet "Installing System Packages (Pacstrap)" pacstrap -K /mnt "${all_pkgs[@]}"
    
    if [[ -f "/mnt/etc/nanorc" ]]; then
        sed -i 's/^# include/include/' /mnt/etc/nanorc
    fi
}

install_bootloader() {
    print_action "Configuring Bootloader (${SELECTED_BOOTLOADER})..."

    if [[ "$SELECTED_BOOTLOADER" == "grub" ]]; then
        if [[ "$BOOT_MODE" == "UEFI" ]]; then
            run_quiet "Installing GRUB (UEFI)" arch-chroot /mnt grub-install --target=x86_64-efi --efi-directory=/boot --bootloader-id=ARCH --recheck
        else
            run_quiet "Installing GRUB (BIOS)" arch-chroot /mnt grub-install --target=i386-pc --recheck "${TARGET_DISK}"
        fi

        # Resolution injection
        if [[ "$ENABLE_TTY_RICE" == "true" && -n "$TTY_RES" ]]; then
            sed -i 's/video=[^ ]*//g' /mnt/etc/default/grub
            sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|&video=${TTY_RES}-32 |" /mnt/etc/default/grub
            sed -i "s/^#*GRUB_GFXMODE=.*/GRUB_GFXMODE=${TTY_RES}x32/" /mnt/etc/default/grub
            echo "GRUB_GFXPAYLOAD_LINUX=keep" >> /mnt/etc/default/grub
        fi

        run_quiet "Generating grub.cfg" arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

    elif [[ "$SELECTED_BOOTLOADER" == "systemd-boot" ]]; then
        run_quiet "Installing systemd-boot" arch-chroot /mnt bootctl install

        local root_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")
        local vmlinuz="vmlinuz-${SELECTED_KERNEL}"
        local initramfs="initramfs-${SELECTED_KERNEL}.img"
        local microcode_img=""
        # Re-detect for assignment logic
        local cpu_vendor=$(grep -m1 "^vendor_id" /proc/cpuinfo | awk '{print $3}')
        if [[ "$cpu_vendor" == "GenuineIntel" ]]; then microcode_img="/intel-ucode.img"; fi
        if [[ "$cpu_vendor" == "AuthenticAMD" ]]; then microcode_img="/amd-ucode.img"; fi

        local options="root=UUID=${root_uuid} rw loglevel=3 quiet"
        if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
            options="cryptdevice=UUID=$(blkid -s UUID -o value ${ROOT_PARTITION}):cryptroot root=/dev/mapper/cryptroot rw loglevel=3 quiet"
        fi
        [[ "$SELECTED_FS" == "btrfs" ]] && options="$options rootflags=subvol=@"

        if [[ "$ENABLE_TTY_RICE" == "true" && -n "$TTY_RES" ]]; then
            options="$options video=${TTY_RES}-32"
        fi

        cat <<EOF_BOOT > /mnt/boot/loader/entries/arch.conf
title   Arch Linux
linux   /${vmlinuz}
$( [[ -n "$microcode_img" ]] && echo "initrd  ${microcode_img}" )
initrd  /${initramfs}
options ${options}
EOF_BOOT
        
        echo -e "default arch.conf\ntimeout 3\nconsole-mode max" > /mnt/boot/loader/loader.conf
        print_subitem "systemd-boot entries created."
    fi
}

try_kexec_boot() {
    if [[ "$ENABLE_KEXEC" != "true" ]]; then return 0; fi

    print_header "FAST BOOT (KEXEC)"
    print_action "Preparing to switch kernels..."

    run_quiet "Installing kexec-tools" pacman -Sy --noconfirm kexec-tools

    local kernel_img="/mnt/boot/vmlinuz-${SELECTED_KERNEL}"
    local initrd_img="/mnt/boot/initramfs-${SELECTED_KERNEL}.img"
    local root_uuid=$(blkid -s UUID -o value "${ROOT_PARTITION}")

    if [[ ! -f "$kernel_img" ]]; then
        error "Kernel not found. Skipping kexec."
        return 1
    fi

    local kexec_args="root=UUID=${root_uuid} rw loglevel=3 quiet"
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then
        kexec_args="cryptdevice=UUID=${root_uuid}:cryptroot root=/dev/mapper/cryptroot rw loglevel=3 quiet"
    fi
    [[ "$SELECTED_FS" == "btrfs" ]] && kexec_args="${kexec_args} rootflags=subvol=@"
    [[ "$ENABLE_TTY_RICE" == "true" && -n "$TTY_RES" ]] && kexec_args="${kexec_args} video=${TTY_RES}-32"

    run_quiet "Loading Kernel" kexec -l "$kernel_img" --initrd="$initrd_img" --append="$kexec_args"

    print_action "Unmounting filesystems..."
    sync
    umount -R /mnt/boot &>/dev/null
    umount -R /mnt &>/dev/null
    if [[ "$ENABLE_ENCRYPTION" == "true" ]]; then cryptsetup close cryptroot &>/dev/null || true; fi
    if [[ -v SWAP_PARTITION && -n "$SWAP_PARTITION" ]]; then swapoff "${SWAP_PARTITION}" &>/dev/null; fi

    echo ""
    echo -e "${C_GREEN}${C_BOLD}:: JUMPING TO NEW SYSTEM...${C_OFF}"
    sleep 2
    kexec -e
    exit 1
}

final_steps() {
    # Scripts Copy
    if [ ${#USER_NAMES[@]} -gt 0 ]; then
        print_action "Copying post-install scripts..."
        for user in "${USER_NAMES[@]}"; do
             mkdir -p "/mnt/home/${user}/Scripts"
             chmod +x ./Scripts/*
             cp ./Scripts/* "/mnt/home/${user}/Scripts/"
             arch-chroot /mnt chown -R "${user}:${user}" "/home/${user}/Scripts"
        done
    fi
    if [ "$ENABLE_ROOT_ACCOUNT" == "true" ]; then
        mkdir -p "/mnt/root/Scripts"
        chmod +x ./Scripts/*
        cp ./Scripts/* "/mnt/root/Scripts/"
    fi
    
    save_logs
    try_kexec_boot

    print_header "INSTALLATION COMPLETE"
    print_subitem "You can now reboot."
    print_subitem "To chroot: arch-chroot /mnt"
    
    # Final unmount try
    sync
    umount -R /mnt &>/dev/null || true
    
    echo ""
    echo -e "${C_GREEN}${C_BOLD}:: Done! Type 'reboot' to restart.${C_OFF}"
    
    INSTALL_SUCCESS="true"
}
