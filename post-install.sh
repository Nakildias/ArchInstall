#!/bin/bash

# Arch Linux Post-Installation Setup Script
# Version: 1.1 (VM detection added)

# --- Configuration ---
SCRIPT_VERSION="1.1"

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
        # Exit here, as this is post-install, less critical to clean up mounts etc.
        exit 1
    fi
    return $status
}

# Check if running as root
check_root() {
    if [ "$EUID" -ne 0 ]; then
        error "This script must be run with root privileges. Please use sudo."
        exit 1
    fi
    # Check if SUDO_USER is set (means script was invoked with sudo)
    if [ -z "$SUDO_USER" ]; then
        error "Could not determine the original user. Please run using 'sudo ./script_name.sh'"
        exit 1
    fi
    info "Running as root for user: ${C_BOLD}${SUDO_USER}${C_OFF}"
}

# --- Feature Functions ---

# 1. Install AUR Helper (yay)
install_aur_helper() {
    info "--- AUR Helper Setup ---"
    if confirm "Install 'yay' AUR helper? (Requires base-devel, git)"; then
        info "Installing prerequisites (base-devel, git)..."
        pacman -S --needed --noconfirm base-devel git
        check_status "Installing prerequisites"

        # Create a temporary directory for building
        local build_dir
        build_dir=$(mktemp -d)
        info "Using temporary build directory: ${build_dir}"

        # Clone, build, and install yay AS THE ORIGINAL USER
        # Need to change ownership of build dir for the user
        chown "${SUDO_USER}:${SUDO_USER}" "${build_dir}"
        check_status "Changing ownership of build directory"

        # Use runuser or sudo -u to switch to the user
        info "Cloning yay repository as user ${SUDO_USER}..."
        sudo -u "$SUDO_USER" git clone https://aur.archlinux.org/yay.git "$build_dir/yay"
        check_status "Cloning yay git repo"

        info "Building and installing yay using makepkg as user ${SUDO_USER}..."
        pushd "$build_dir/yay" > /dev/null
            # makepkg needs to run as non-root; -s installs deps, -i installs package (will prompt sudo if needed)
            sudo -u "$SUDO_USER" makepkg -si --noconfirm
            check_status "Running makepkg -si for yay"
        popd > /dev/null

        # Clean up
        info "Removing temporary build directory..."
        rm -rf "$build_dir"

        success "'yay' AUR helper installed successfully."
        YAY_INSTALLED=true # Flag for later use if needed
    else
        info "Skipping AUR helper installation."
        YAY_INSTALLED=false
    fi
}

# 2. Install Graphics Drivers (including VM guest tools)
install_gpu_drivers() {
    info "--- Graphics Driver / VM Guest Tools Setup ---"
    if ! confirm "Attempt to detect and install graphics drivers or VM guest tools?"; then
        info "Skipping graphics driver/VM tools installation."
        return
    fi

    local pkgs_to_install=()
    local vm_type="none"
    local vm_tools_installed=false

    # --- Virtual Machine Detection ---
    info "Checking for virtualization environment..."
    if command -v systemd-detect-virt &>/dev/null; then
        vm_type=$(systemd-detect-virt --container --vm) # Detects both VMs and containers
        # Treat containers as 'none' for graphics purposes unless specifically handled
        case "$vm_type" in
            qemu|kvm|bochs)
                info "Detected QEMU/KVM/Bochs environment."
                if confirm "Install QEMU/Spice guest tools (spice-vdagent, mesa)?"; then
                     # mesa includes virglrenderer for 3D, qxl driver might be separate if needed
                    pkgs_to_install+=(spice-vdagent mesa xf86-video-qxl)
                    vm_tools_installed=true
                fi
                ;;
            vmware)
                info "Detected VMware environment."
                if confirm "Install VMware guest tools (open-vm-tools, xf86-video-vmware)?"; then
                    pkgs_to_install+=(open-vm-tools xf86-video-vmware)
                    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
                        info "Installing selected VM tools..."
                        pacman -S --needed --noconfirm "${pkgs_to_install[@]}"
                        check_status "Installing VMware guest tools"
                        info "Enabling and starting VMware tools service..."
                        systemctl enable --now vmtoolsd.service
                        check_status "Enabling vmtoolsd service"
                        success "VMware guest tools installed and service enabled."
                        vm_tools_installed=true
                        pkgs_to_install=() # Reset array as we installed them already
                    fi
                fi
                ;;
            oracle) # Corresponds to VirtualBox
                info "Detected VirtualBox environment."
                if confirm "Install VirtualBox guest additions (virtualbox-guest-utils)?"; then
                    pkgs_to_install+=(virtualbox-guest-utils)
                     if [ ${#pkgs_to_install[@]} -gt 0 ]; then
                        info "Installing selected VM tools..."
                        pacman -S --needed --noconfirm "${pkgs_to_install[@]}"
                        check_status "Installing VirtualBox guest additions"
                        info "Enabling VirtualBox guest service..."
                        # The service might vary slightly, but vboxservice is common
                        systemctl enable --now vboxservice.service
                        check_status "Enabling vboxservice service"
                        warn "A reboot is usually required for VirtualBox guest additions to fully function."
                        success "VirtualBox guest additions installed and service enabled."
                        vm_tools_installed=true
                        pkgs_to_install=() # Reset array as we installed them already
                     fi
                fi
                ;;
            *)
                if [ "$vm_type" != "none" ]; then
                    warn "Detected virtualization type '$vm_type', but no specific guest tools configured for it in this script."
                else
                    info "No known VM environment detected or running on bare metal."
                fi
                vm_type="none" # Treat unknown/unhandled VMs or containers as none for physical GPU check
                ;;
        esac
    else
        warn "Cannot find 'systemd-detect-virt'. Unable to reliably detect virtual machine environment. Falling back to hardware detection."
        vm_type="none"
    fi

    # --- Physical Hardware Detection (only if VM tools weren't installed) ---
    if ! $vm_tools_installed && [ "$vm_type" == "none" ]; then
        info "Proceeding with physical hardware detection..."
        # Detect GPU vendor(s) using lspci
        local intel_gpu=false
        local nvidia_gpu=false
        local amd_gpu=false

        info "Detecting VGA-compatible controllers..."
        # Use loop to read lines safely
        while IFS= read -r line; do
            info " Found: $line"
            if echo "$line" | grep -iq "intel"; then intel_gpu=true; fi
            if echo "$line" | grep -iq "nvidia"; then nvidia_gpu=true; fi
            if echo "$line" | grep -iqE "amd|ati|radeon"; then amd_gpu=true; fi
        done < <(lspci | grep -iE 'vga|3d|display')

        # --- Intel ---
        if $intel_gpu; then
            info "Intel GPU detected."
            if confirm "Install open-source Intel drivers (mesa, vulkan-intel, intel-media-driver)?"; then
                pkgs_to_install+=(mesa vulkan-intel intel-media-driver libva-intel-driver) # Add older driver too for compatibility
            fi
        fi

        # --- AMD ---
        if $amd_gpu; then
            info "AMD/ATI GPU detected."
            if confirm "Install open-source AMD drivers (mesa, vulkan-radeon, libva-mesa-driver, mesa-vdpau)?"; then
                pkgs_to_install+=(mesa vulkan-radeon libva-mesa-driver mesa-vdpau xf86-video-amdgpu) # Add DDX driver too
            fi
        fi

        # --- NVIDIA ---
        if $nvidia_gpu; then
            info "NVIDIA GPU detected."
            if confirm "Install proprietary NVIDIA drivers (nvidia-dkms, nvidia-utils, libva-nvidia-driver)? (Requires kernel headers)"; then
                # Install headers for currently running kernel and common LTS kernel
                # Note: This might not match the *installed* kernel if user booted fallback
                warn "Ensuring kernel headers are installed (may take a moment)..."
                # Safer to install common headers
                pacman -S --needed --noconfirm linux-headers linux-lts-headers # Install for standard and LTS
                check_status "Installing kernel headers"

                pkgs_to_install+=(nvidia-dkms nvidia-utils libva-nvidia-driver) # Use DKMS version for wider kernel compatibility
                warn "Proprietary NVIDIA drivers selected. You might need to regenerate initramfs (mkinitcpio -P) and configure modules/modesetting depending on your setup (e.g., Wayland)."
            elif confirm "Install open-source NVIDIA drivers (mesa)? (Usually sufficient for basic display)"; then
                pkgs_to_install+=(mesa) # Mesa includes nouveau
            fi
        fi
    fi # End physical hardware detection block

    # Install selected packages (VM or physical)
    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        # Remove duplicates (e.g., mesa added multiple times)
        local unique_pkgs=($(echo "${pkgs_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        info "Installing GPU driver/VM packages: ${unique_pkgs[*]}"
        pacman -S --needed --noconfirm "${unique_pkgs[@]}"
        check_status "Installing GPU/VM packages"
        success "Selected GPU driver/VM packages installed."
    elif ! $vm_tools_installed; then
         # Only show this if we didn't install VM tools OR physical drivers
        info "No GPU driver or VM tool packages selected for installation."
    fi
}


# 3. Install Virtualization Tools
install_virt_tools() {
    info "--- Virtualization Setup (QEMU/KVM/Libvirt) ---"
    if confirm "Install QEMU, KVM, Libvirt, and Virtual Machine Manager?"; then
        local pkgs=(
            qemu-desktop  # Common set of QEMU tools for desktop use
            libvirt       # Virtualization API library
            virt-manager  # GUI for managing VMs
            dnsmasq       # Needed for default libvirt networking
            edk2-ovmf     # UEFI firmware for guests
            bridge-utils  # For network bridging
        )
        info "Installing virtualization packages: ${pkgs[*]}"
        pacman -S --needed --noconfirm "${pkgs[@]}"
        check_status "Installing virtualization packages"

        info "Enabling and starting libvirtd service..."
        systemctl enable --now libvirtd.service
        check_status "Enabling/starting libvirtd service"

        info "Adding user '${SUDO_USER}' to the 'libvirt' group..."
        usermod -aG libvirt "$SUDO_USER"
        check_status "Adding user to libvirt group"
        warn "You may need to log out and log back in for the group change to take effect."

        # Check KVM module status
        if lsmod | grep -q kvm; then
            success "KVM modules appear to be loaded."
        else
            warn "KVM kernel modules (kvm_intel or kvm_amd) not detected. Ensure virtualization is enabled in your BIOS/UEFI."
        fi

        success "Virtualization tools installed and configured."
    else
        info "Skipping virtualization tools installation."
    fi
}

# 4. Install Office Suite
install_office() {
    info "--- Office Suite Setup ---"
    if confirm "Install an office suite?"; then
        local office_options=(
            "LibreOffice Fresh (Latest Features)"
            "LibreOffice Still (More Stable)"
            "OnlyOffice (Community Repo Version)"
            "None"
        )
        local office_pkgs=(
            "libreoffice-fresh"
            "libreoffice-still"
            "onlyoffice-desktopeditors"
            ""
        )

        echo "Available Office Suites:"
        select choice in "${office_options[@]}"; do
            if [[ -n "$choice" ]]; then
                local selected_pkg=${office_pkgs[$((REPLY-1))]}
                if [[ -n "$selected_pkg" ]]; then
                    info "Installing ${choice}..."
                    pacman -S --needed --noconfirm "$selected_pkg"
                    check_status "Installing ${choice}"
                    success "${choice} installed."
                else
                    info "No office suite selected."
                fi
                break
            else
                error "Invalid selection."
            fi
        done
    else
        info "Skipping office suite installation."
    fi
}

# 5. Permanently Mount Drives
setup_fstab() {
    info "--- Permanent Drive Mounting (/etc/fstab) ---"
    warn "Modifying /etc/fstab can make your system unbootable if done incorrectly!"
    warn "This feature helps add *additional* drives after Arch is installed and running."
    warn "It should be run *after* chrooting into the installed system or *after* the first boot."
    warn "Ensure you understand which partition you are selecting."

    if ! confirm "Do you want to attempt to permanently mount additional drives via /etc/fstab?"; then
        info "Skipping fstab modifications."
        return
    fi

    # --- CRITICAL CHECK: Verify system seems booted/chrooted ---
    info "Verifying system state (checking for mounted / and /boot in fstab)..."
    if ! findmnt / > /dev/null; then
        error "/ is NOT currently mounted. This script should be run from the installed system (chroot or booted). Aborting."
        return 1
    fi
     if ! findmnt /boot > /dev/null; then
        warn "/boot is NOT currently mounted. This might be okay for some setups, but standard Arch installs require it. Proceed with extra caution."
        # Allow proceeding but warn heavily. Might be separate /boot/efi or no separate /boot.
    fi
    if ! grep -qE '^[[:space:]]*[^#]+[[:space:]]+/[[:space:]]' /etc/fstab; then
        error "Root ('/') entry NOT found in /etc/fstab. Is this the installed system's fstab? Aborting."
        return 1
    fi
     if ! grep -qE '^[[:space:]]*[^#]+[[:space:]]+/boot[[:space:]]' /etc/fstab && findmnt /boot > /dev/null; then
         # Only error about missing /boot in fstab if /boot is actually mounted separately
        error "/boot is mounted but NOT found in /etc/fstab. Aborting fstab modification."
        return 1
    fi
    success "System appears to be booted or chrooted correctly. Proceeding with caution."
    # --- End Critical Check ---

    info "Identifying potential partitions to mount (filesystems present, not mounted root/boot/swap)..."

    # Get list of partitions with UUID, FSTYPE, but no current MOUNTPOINT
    # Exclude root ('/'), boot ('/boot'), and swap partitions
    local root_dev boot_dev swap_devs
    root_dev=$(findmnt -n -o SOURCE /)
    # Handle cases where /boot might not be separate
    boot_dev=""
    if findmnt -n -o SOURCE /boot &>/dev/null; then
        boot_dev=$(findmnt -n -o SOURCE /boot)
    fi

    # Get devices used for swap
    mapfile -t swap_devs < <(swapon --show=NAME --noheadings)

    # Build exclude pattern dynamically
    local exclude_pattern="${root_dev}"
    if [[ -n "$boot_dev" ]]; then
         exclude_pattern+="|${boot_dev}"
    fi
    for dev in "${swap_devs[@]}"; do
        exclude_pattern+="|${dev}"
    done
    # Also exclude loop devices and CD/DVD ROM devices
    exclude_pattern+="|/dev/loop|/dev/sr[0-9]+"


    mapfile -t candidates < <(lsblk -dnpo NAME,UUID,FSTYPE,SIZE,TYPE | awk -v exclude="^(${exclude_pattern})" '$2 != "" && $3 != "" && $3 != "swap" && $5 == "part" && $1 !~ exclude { print $1 " (" $3 ", " $4 ", UUID=" $2 ")" }')
    # $5 == "part" ensures we only list partitions, not whole disks

    if [ ${#candidates[@]} -eq 0 ]; then
        info "No suitable unmounted partitions with filesystems found to add to fstab."
        return
    fi

    info "Found the following potential partitions:"
    PS3="$(echo -e "${C_PURPLE}${C_BOLD}[PROMPT]${C_OFF} Select partition to mount (or 'Quit'): ")"
    select cand_choice in "${candidates[@]}" "Quit"; do
        if [[ "$cand_choice" == "Quit" ]]; then
            info "Exiting fstab setup."
            break
        elif [[ -n "$cand_choice" ]]; then
            local device_info=($cand_choice) # Split into array
            local device_name="${device_info[0]}"
            local fs_type=$(echo "$cand_choice" | grep -oP '\(\K[^,]+')
            local uuid=$(echo "$cand_choice" | grep -oP 'UUID=\K[^)]+')

            info "Selected Partition: ${device_name}"
            info "  UUID: ${uuid}"
            info "  Filesystem: ${fs_type}"

            local mount_point=""
            while true; do
                prompt "Enter mount point path (e.g., /mnt/data, /media/mydisk). It will be created if needed: " mount_point
                if [[ -z "$mount_point" ]]; then
                    error "Mount point cannot be empty."
                elif [[ "$mount_point" =~ ^/[^[:space:]]+ ]]; then # Basic validation: starts with / and no spaces
                    # Check if mount point already exists and is a directory
                    if [[ -e "$mount_point" && ! -d "$mount_point" ]]; then
                        error "'${mount_point}' exists but is not a directory."
                    # Check if mount point is already in use (in fstab or currently mounted by something else)
                    elif grep -qE "^\s*[^#]+\s+${mount_point}(\s|$)+" /etc/fstab; then
                         # Added (\s|$) to match end of field exactly
                        error "'${mount_point}' is already configured as a mount point in /etc/fstab."
                    elif findmnt "${mount_point}" > /dev/null; then
                        error "'${mount_point}' is already mounted."
                    else
                        break # Valid path
                    fi
                else
                    error "Invalid mount point format. Must be an absolute path without spaces."
                fi
            done

            local fstab_options="defaults,nofail,x-gvfs-show" # nofail is crucial, x-gvfs-show helps GUI display

            local fstab_entry="UUID=${uuid} ${mount_point} ${fs_type} ${fstab_options} 0 2"

            warn "The following line will be ADDED to /etc/fstab:"
            echo -e "${C_YELLOW}${fstab_entry}${C_OFF}"

            if confirm "Add this entry to /etc/fstab?"; then
                info "Creating mount point directory (if it doesn't exist)..."
                mkdir -p "${mount_point}"
                check_status "Creating mount point ${mount_point}"
                # Ownership? Keep as root for now, user can chown later if needed.

                info "Backing up /etc/fstab to /etc/fstab.bak..."
                cp /etc/fstab /etc/fstab.bak
                check_status "Backing up fstab"

                info "Adding entry to /etc/fstab..."
                echo "${fstab_entry}" >> /etc/fstab
                check_status "Appending to fstab"

                info "Reloading systemd mount units..."
                systemctl daemon-reload
                check_status "Running systemctl daemon-reload"


                info "Attempting to mount the new filesystem ('mount ${mount_point}')..."
                # Mount specifically the new point instead of 'mount -a' for safety
                if mount "${mount_point}"; then
                    success "Filesystem mounted successfully to '${mount_point}'."
                    # Verify it's the correct device mounted
                     local mounted_dev
                     mounted_dev=$(findmnt -n -o SOURCE "${mount_point}")
                     if [[ "$mounted_dev" == "$device_name" || "$mounted_dev" == "/dev/disk/by-uuid/${uuid}" ]]; then
                         success "Verified correct device (${mounted_dev}) is mounted."
                     else
                         warn "Mounted device (${mounted_dev}) doesn't immediately match expected (${device_name} or UUID). Check 'findmnt ${mount_point}'."
                     fi

                else
                    error "'mount ${mount_point}' failed! Check /etc/fstab manually. The incorrect line was added."
                    error "Attempting to restore fstab from /etc/fstab.bak..."
                    if cp /etc/fstab.bak /etc/fstab; then
                         success "Restored /etc/fstab from backup."
                         # Remove the created mount point if empty? Maybe safer not to.
                         # rm -df "${mount_point}" # Careful, only if empty
                    else
                         error "FAILED TO RESTORE fstab! Please manually fix /etc/fstab using /etc/fstab.bak IMMEDIATELY."
                    fi
                     error "Please investigate /etc/fstab before rebooting!"
                fi
            else
                info "Skipping fstab entry for ${device_name}."
            fi
            # Exit select loop after processing one entry. User can run again if needed.
            info "Exiting fstab setup after processing one entry. Run script again to add more."
            break
        else
            error "Invalid selection."
        fi
        # REPLY="" # Clear REPLY - not needed since we break
        # echo "----------------------------------------" # Not needed since we break
    done
}


# 6. Install Media Codecs
install_codecs() {
    info "--- Media Codecs Setup ---"
    if confirm "Install common media codecs (GStreamer good/bad/ugly/libav)?"; then
        local pkgs=(
            gst-plugins-good
            gst-plugins-bad
            gst-plugins-ugly
            gst-libav # FFmpeg plugin
            # libdvdcss # Requires AUR or specific repo - skip for now
        )
        info "Installing media codecs: ${pkgs[*]}"
        pacman -S --needed --noconfirm "${pkgs[@]}"
        check_status "Installing media codecs"
        success "Common media codecs installed."
    else
        info "Skipping media codec installation."
    fi
}

# --- Main Execution ---

main() {
    info "Starting Arch Linux Post-Install Setup Script v${SCRIPT_VERSION}"
    check_root # Ensure script is run with sudo

    # Call feature functions
    install_aur_helper
    install_gpu_drivers
    install_virt_tools
    install_office
    # Run fstab setup carefully
    setup_fstab || warn "fstab setup aborted or failed. Check messages above."
    install_codecs

    echo
    success "--- Post-Installation Setup Complete ---"
    info "Please review the output above for any warnings or necessary actions (like logging out/in or rebooting)."
    info "Remember to configure backups and firewall rules for your system."
}

# Run the main function
main

exit 0
