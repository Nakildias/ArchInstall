#!/bin/bash

# Arch Linux Post-Installation Setup Script
# Version: 1.0

# --- Configuration ---
SCRIPT_VERSION="1.0"

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

# 2. Install Graphics Drivers
install_gpu_drivers() {
    info "--- Graphics Driver Setup ---"
    if ! confirm "Attempt to detect and install graphics drivers?"; then
        info "Skipping graphics driver installation."
        return
    fi

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

    local pkgs_to_install=()

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
            local current_kernel
            current_kernel=$(uname -r | cut -d '-' -f 2) # Extracts 'arch1' etc. Needs mapping to package.
            # Safer to install common headers
            pacman -S --needed --noconfirm linux-headers linux-lts-headers # Install for standard and LTS
            check_status "Installing kernel headers"

            pkgs_to_install+=(nvidia-dkms nvidia-utils libva-nvidia-driver) # Use DKMS version for wider kernel compatibility
            warn "Proprietary NVIDIA drivers selected. You might need to regenerate initramfs (mkinitcpio -P) and configure modules/modesetting depending on your setup (e.g., Wayland)."
        elif confirm "Install open-source NVIDIA drivers (mesa)? (Usually sufficient for basic display)"; then
             pkgs_to_install+=(mesa) # Mesa includes nouveau
        fi
    fi

    # Install selected packages
    if [ ${#pkgs_to_install[@]} -gt 0 ]; then
        # Remove duplicates (e.g., mesa added multiple times)
        local unique_pkgs=($(echo "${pkgs_to_install[@]}" | tr ' ' '\n' | sort -u | tr '\n' ' '))
        info "Installing GPU driver packages: ${unique_pkgs[*]}"
        pacman -S --needed --noconfirm "${unique_pkgs[@]}"
        check_status "Installing GPU packages"
        success "Selected GPU driver packages installed."
    else
        info "No GPU driver packages selected for installation."
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
    warn "This feature is experimental. Proceed with caution."

    if ! confirm "Do you want to attempt to permanently mount additional drives via /etc/fstab?"; then
        info "Skipping fstab modifications."
        return
    fi

    # --- CRITICAL CHECK: Verify /boot is mounted and in fstab ---
    info "Verifying /boot partition status..."
    if ! findmnt /boot > /dev/null; then
        error "/boot is NOT currently mounted. Aborting fstab modification."
        return 1 # Return non-zero to indicate failure/abort
    fi
    if ! grep -qE '^[[:space:]]*[^#]+[[:space:]]+/boot[[:space:]]' /etc/fstab; then
        error "/boot entry NOT found in /etc/fstab. Aborting fstab modification."
        return 1 # Return non-zero to indicate failure/abort
    fi
    success "/boot appears to be mounted and configured in fstab. Proceeding with caution."
    # --- End Critical Check ---

    info "Identifying potential partitions to mount (filesystems present, not mounted, not swap, not root, not boot)..."

    # Get list of partitions with UUID, FSTYPE, but no current MOUNTPOINT
    # Exclude root ('/'), boot ('/boot'), and swap partitions
    local root_dev boot_dev swap_devs
    root_dev=$(findmnt -n -o SOURCE /)
    boot_dev=$(findmnt -n -o SOURCE /boot)
    # Get devices used for swap
    mapfile -t swap_devs < <(swapon --show=NAME --noheadings)

    # Build exclude pattern dynamically
    local exclude_pattern="${root_dev}|${boot_dev}"
    for dev in "${swap_devs[@]}"; do
        exclude_pattern+="|${dev}"
    done
    # Also exclude partitions on the same physical disk as root/boot if possible? Complex. Keep simple first.
    # Exclude loop devices
    exclude_pattern+="|/dev/loop"


    mapfile -t candidates < <(lsblk -dnpo NAME,UUID,FSTYPE,SIZE | awk -v exclude="^(${exclude_pattern})" '$2 != "" && $3 != "" && $3 != "swap" && $1 !~ exclude { print $1 " (" $3 ", " $4 ", UUID=" $2 ")" }')

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
                    elif grep -qE "^\s*[^#]+\s+${mount_point}\s+" /etc/fstab; then
                         error "'${mount_point}' is already configured in /etc/fstab."
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

                info "Attempting to mount all filesystems ('mount -a')..."
                if mount -a; then
                    success "Filesystem mounted successfully via 'mount -a'."
                else
                    error "'mount -a' failed! Check /etc/fstab manually. Restoring backup from /etc/fstab.bak may be necessary."
                    # Attempt to restore backup? Could be risky if original was bad.
                    # cp /etc/fstab.bak /etc/fstab
                    error "Please investigate /etc/fstab before rebooting!"
                fi
            else
                info "Skipping fstab entry for ${device_name}."
            fi
        else
            error "Invalid selection."
        fi
        # Prompt again after processing one
        REPLY="" # Clear REPLY to force prompt regeneration
        echo "----------------------------------------"
        info "Found the following potential partitions:" # Show list again
        # This re-listing logic inside select isn't ideal, better to loop outside select.
        # Let's simplify: process one then exit this feature. User can run script again.
         info "Exiting fstab setup after processing one entry. Run script again to add more."
         break # Exit select loop after processing one
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
    # Run fstab setup carefully - check return code?
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
