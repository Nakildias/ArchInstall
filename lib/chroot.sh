#!/bin/bash

# --- Chroot Phase ---

configure_installed_system() {
    info "Configuring the installed system (within chroot)..."

    # --- Initialize Theme Variables (Prevent Unbound Errors) ---
    SELECTED_THEME_FILE="${SELECTED_THEME_FILE:-}"
    THEME_YAY_DEPS="${THEME_YAY_DEPS:-}"
    BUILD_USER="${USER_NAMES[0]:-root}"
    THEME_WALLPAPER_FILENAME="${THEME_WALLPAPER_FILENAME:-}"
    THEME_WALLPAPER_SRC="${THEME_WALLPAPER_SRC:-}"
    TARGET_THEME_USERS="${TARGET_THEME_USERS:-}"
    # -----------------------------------------------------------

    # Retrieve the Display Manager choice saved in the previous function
    if [ -f /tmp/arch_install_dm_choice ]; then
        source /tmp/arch_install_dm_choice
        ENABLE_DM="$DM_SERVICE"
        # TARGET_SESSION_NAME is now available from this source
    else
        ENABLE_DM=""
        AUTO_LOGIN_USER=""
        TARGET_SESSION_NAME=""
    fi

    ENABLE_TTY_RICE="${ENABLE_TTY_RICE:-false}"
    TTY_RES="${TTY_RES:-}"
    TTY_THEME_ID="${TTY_THEME_ID:-}"
    SELECTED_TTY_CONFIG="${SELECTED_TTY_CONFIG:-}"

    # --- LOAD TTY THEME PROCEDURALLY ---
    T_COLORS_DEF=""
    P10K_URL_VAL=""
    
    if [[ -n "$SELECTED_TTY_CONFIG" && -f "$SELECTED_TTY_CONFIG" ]]; then
        info "Loading TTY Configuration: $(basename "$SELECTED_TTY_CONFIG")"
        (
            source "$SELECTED_TTY_CONFIG"
            # Print the array definition as a string: ("val1" "val2" ...)
            echo "T_COLORS=($(printf "\"%s\" " "${T_COLORS[@]}"))" > /tmp/tty_colors_def
            echo "P10K_URL=\"$P10K_URL\"" > /tmp/p10k_url_def
        )
        T_COLORS_DEF=$(cat /tmp/tty_colors_def)
        P10K_URL_VAL=$(source /tmp/p10k_url_def && echo "$P10K_URL")
        rm /tmp/tty_colors_def /tmp/p10k_url_def
    else
        # Fallback Default (Nord) if enabled but no config
        if [[ "$ENABLE_TTY_RICE" == "true" ]]; then
             T_COLORS_DEF='T_COLORS=("2e3440" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "88c0d0" "e5e9f0" "4c566a" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "8fbcbb" "eceff4")'
             P10K_URL_VAL="https://raw.githubusercontent.com/nordtheme/powerlevel10k/master/files/.p10k.zsh"
        fi
    fi

    # --- THEME PREPARATION ---
    if [[ -n "$SELECTED_THEME_FILE" ]]; then
        info "Copying theme files for chroot..."
        mkdir -p /mnt/opt/archinstall_themes
        
        # Ensure we are copying the file from the new DE-Themes location
        cp "$SELECTED_THEME_FILE" /mnt/opt/archinstall_themes/

        # Verify and copy wallpaper from the new procedural path
        if [[ -n "$THEME_WALLPAPER_SRC" ]]; then
            if [[ -f "$THEME_WALLPAPER_SRC" ]]; then
                cp "$THEME_WALLPAPER_SRC" /mnt/opt/archinstall_themes/
                info "Wallpaper copied successfully: $(basename "$THEME_WALLPAPER_SRC")"
            else
                warn "Wallpaper not found at: $THEME_WALLPAPER_SRC"
                # Clear variables so chroot doesn't try to use a missing file
                THEME_WALLPAPER_FILENAME=""
            fi
        fi
    fi

    # Convert "all" keyword to the actual list of users created during the session
    if [[ "$TARGET_THEME_USERS" == "all" ]]; then
        TARGET_THEME_USERS="${USER_NAMES[*]}"
    fi

    # Generate fstab
    info "Generating fstab..."
    # Use -U for UUIDs (recommended)
    genfstab -U /mnt >> /mnt/etc/fstab
    check_status "Generating fstab"

    # Copy necessary host configurations into chroot environment
    info "Copying essential configuration files to chroot..."
    cp /etc/pacman.d/mirrorlist /mnt/etc/pacman.d/mirrorlist
    check_status "Copying mirrorlist to /mnt"
    cp /etc/pacman.conf /mnt/etc/pacman.conf
    check_status "Copying pacman.conf to /mnt"

    # --- PREPARE VARIABLES ---
    # Calculate filename safely (returns empty string if no theme selected)
    if [[ -n "$SELECTED_THEME_FILE" ]]; then
        SAFE_THEME_FILENAME="$(basename "$SELECTED_THEME_FILE")"
    else
        SAFE_THEME_FILENAME=""
    fi

# --- PRE-CALCULATE SANITIZED ARRAYS FOR HEREDOC INJECTION ---
# We must do this IN THE HOST script, so the values are expanded safely into the heredoc.

# 1. User Names
SAFE_USER_NAMES_STR="("
for v in "${USER_NAMES[@]}"; do SAFE_USER_NAMES_STR+="$(printf %q "$v") "; done
SAFE_USER_NAMES_STR+=")"

# 2. User Passwords (Critical for special chars)
SAFE_USER_PASSWORDS_STR="("
for v in "${USER_PASSWORDS[@]}"; do SAFE_USER_PASSWORDS_STR+="$(printf %q "$v") "; done
SAFE_USER_PASSWORDS_STR+=")"

# 3. User Sudo
SAFE_USER_SUDO_STR="("
for v in "${USER_SUDO[@]}"; do SAFE_USER_SUDO_STR+="$(printf %q "$v") "; done
SAFE_USER_SUDO_STR+=")"

# 4. Root Password
SAFE_ROOT_PASSWORD_VAL=$(printf %q "${ROOT_PASSWORD}")

# Create chroot configuration script using Split Heredoc
info "Creating chroot configuration script..."
    
# --- STEP 1: GENERATE SHARED ENVIRONMENT FILE ---
# This file contains all variables and functions needed by sub-tasks
# We use a trick to export arrays by declaring them
cat <<EOF_ENV > /mnt/etc/chroot_env.sh
#!/bin/bash
# Shared Environment Variables & Functions

# Variables
HOSTNAME="${HOSTNAME}"
ENABLE_DM="${ENABLE_DM}"
SELECTED_DE_NAME="${SELECTED_DE_NAME:-}"
AUTO_LOGIN_USER="${AUTO_LOGIN_USER}"
TARGET_SESSION_NAME="${TARGET_SESSION_NAME}"
ENABLE_ENCRYPTION="${ENABLE_ENCRYPTION}"
ROOT_PARTITION="${ROOT_PARTITION}"
SELECTED_FS="${SELECTED_FS}"
SWAP_TYPE="${SWAP_TYPE}"
VERBOSE_MODE="${VERBOSE_MODE}"
INSTALL_VMWARE=${INSTALL_VMWARE}
INSTALL_QEMU=${INSTALL_QEMU}
INSTALL_STEAM=${INSTALL_STEAM}
INSTALL_ZSH=${INSTALL_ZSH}
INSTALL_UFW=${INSTALL_UFW}
INSTALL_YAY=${INSTALL_YAY}
ENABLE_MULTILIB=${ENABLE_MULTILIB}
DEFAULT_REGION="${DEFAULT_REGION}"
DEFAULT_CITY="${DEFAULT_CITY}"
SYSTEM_LOCALE="${SYSTEM_LOCALE:-en_US.UTF-8}"
SYSTEM_KEYMAP="${SYSTEM_KEYMAP:-us}"
PARALLEL_DL_COUNT="${PARALLEL_DL_COUNT:-$DEFAULT_PARALLEL_DL}"

ENABLE_TTY_RICE="${ENABLE_TTY_RICE}"
TTY_RES="${TTY_RES}"
# Inject Arrays
${T_COLORS_DEF}

# User Arrays (Sanitized Injection)
USER_NAMES=${SAFE_USER_NAMES_STR}
USER_PASSWORDS=${SAFE_USER_PASSWORDS_STR}
USER_SUDO=${SAFE_USER_SUDO_STR}
ROOT_PASSWORD=${SAFE_ROOT_PASSWORD_VAL}

BUILD_USER="${USER_NAMES[0]}"
P10K_URL="${P10K_URL_VAL}"

# Theme Vars
SELECTED_THEME_FILENAME="${SAFE_THEME_FILENAME}"
THEME_YAY_DEPS="${THEME_YAY_DEPS}"
THEME_WALLPAPER_FILENAME="${THEME_WALLPAPER_FILENAME}"
THEME_WALLPAPER_SRC="${THEME_WALLPAPER_SRC}"
TARGET_THEME_USERS="${TARGET_THEME_USERS}"

# Functions
# Functions
C_OFF='\033[0m'; C_RED='\033[0;31m'; C_GREEN='\033[0;32m'; C_YELLOW='\033[0;33m'; C_BLUE='\033[1;34m'; C_CYAN='\033[1;36m'; C_BOLD='\033[1m'

info() { echo -e "\${C_BLUE}\${C_BOLD}::\${C_OFF} \${C_BOLD}\$1\${C_OFF}"; }
error() { echo -e "\${C_RED}\${C_BOLD}:: ERROR:\${C_OFF} \$1"; exit 1; }
success() { echo -e "   \${C_GREEN}->\${C_OFF} \$1"; }
warn() { echo -e "\${C_YELLOW}\${C_BOLD}:: WARNING:\${C_OFF} \$1"; }

check_status_chroot() {
    local status=\$?
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; fi
    if [ \$status -ne 0 ]; then error "Chroot command failed with status \$status: \$1"; fi
    return \$status
}

exec_silent() {
    if [[ "\${VERBOSE_MODE}" == "true" ]]; then
        "\$@"
    else
        "\$@" >/dev/null 2>&1
    fi
}

# --- INJECTED NETWORK RESILIENCE FUNCTIONS ---


wait_for_internet() {
    local host="https://archlinux.org"
    local fallback="https://google.com"
    local max_retries=60
    local retries=0
    if curl -I --connect-timeout 3 -s "\$host" &>/dev/null; then return 0; fi
    echo -e "\${C_YELLOW}[NETWORK]\${C_OFF} Connection lost. Waiting (max 5 min)..."
    while [ \$retries -lt \$max_retries ]; do
        if curl -I --connect-timeout 3 -s "\$host" &>/dev/null || curl -I --connect-timeout 3 -s "\$fallback" &>/dev/null; then
            echo -e "\${C_GREEN}[NETWORK]\${C_OFF} Restored."
            return 0
        fi
        ((retries++))
        sleep 5
    done
    echo -e "\${C_RED}[NETWORK]\${C_OFF} Timeout after 5 minutes."
    return 1
}

run_with_retry() {
    local max_retries=10
    local count=0
    while [ \$count -lt \$max_retries ]; do
        "\$@"
        if [ \$? -eq 0 ]; then return 0; fi
        count=\$((count + 1))
        echo -e "\${C_YELLOW}[RETRY]\${C_OFF} Command failed (\$count/\$max_retries). Checking network..."
        wait_for_internet
        sleep 5
    done
    return 1
}
export -f info error success warn wait_for_internet run_with_retry
EOF_ENV
    chmod +x /mnt/etc/chroot_env.sh

    # --- STEP 2: COPY CUSTOMIZERS ---
    # Copy all customizers? Or just active ones?
    # Copying all for flexibility, or just active. User asked for active check copy.
    
    if [[ "${ENABLE_TTY_RICE}" == "true" ]]; then
       cp "${SCRIPT_DIR}/Customizers/Base-TTY.sh" /mnt/root/Base-TTY.sh
       chmod +x /mnt/root/Base-TTY.sh
    fi
    
    if [[ "${SELECTED_DE_NAME:-}" == "Hyprland" ]]; then
       cp "${SCRIPT_DIR}/Customizers/Hyprland.sh" /mnt/root/Hyprland.sh
       chmod +x /mnt/root/Hyprland.sh
    fi

    if [[ -n "${SAFE_THEME_FILENAME}" ]]; then
       cp "${SCRIPT_DIR}/Customizers/KDE-Plasma.sh" /mnt/root/KDE-Plasma.sh
       chmod +x /mnt/root/KDE-Plasma.sh
    fi

    # --- STEP 3: MAIN CHROOT SCRIPT (DISPATCHER) ---
    cat <<CHROOT_HEADER > /mnt/configure_chroot.sh
#!/bin/bash
# This script runs inside the chroot environment
set -e
set -o pipefail

# 1. Load Shared Environment
source /etc/chroot_env.sh

# 2. Basic Configuration (Locale, Time, Hostname)
info "Setting timezone to \${DEFAULT_REGION}/\${DEFAULT_CITY}..."
ln -sf "/usr/share/zoneinfo/\${DEFAULT_REGION}/\${DEFAULT_CITY}" /etc/localtime
hwclock --systohc

# Locale and Keymap (user-selected or default US)
info "Configuring locale: \${SYSTEM_LOCALE}, keymap: \${SYSTEM_KEYMAP}..."
echo "\${SYSTEM_LOCALE} UTF-8" > /etc/locale.gen
locale-gen
echo "LANG=\${SYSTEM_LOCALE}" > /etc/locale.conf
echo "KEYMAP=\${SYSTEM_KEYMAP}" > /etc/vconsole.conf
echo "\${HOSTNAME}" > /etc/hostname
cat <<EOF_HOSTS > /etc/hosts
127.0.0.1   localhost
::1         localhost
127.0.1.1   \${HOSTNAME}.localdomain \${HOSTNAME}
EOF_HOSTS



# 6. Final Steps (Sudoers, Services)
# Retaining the tail logic for services...
CHROOT_HEADER


# --- INJECT THEME VARIABLES ---

    # Calculate filename safely (returns empty string if no theme selected)
    # This prevents 'basename' from returning '.' when the variable is empty
    if [[ -n "$SELECTED_THEME_FILE" ]]; then
        SAFE_THEME_FILENAME="$(basename "$SELECTED_THEME_FILE")"
    else
        SAFE_THEME_FILENAME=""
    fi

    cat <<EOF_THEME_VARS >> /mnt/configure_chroot.sh
SELECTED_THEME_FILENAME="${SAFE_THEME_FILENAME}"
THEME_YAY_DEPS="${THEME_YAY_DEPS}"
THEME_WALLPAPER_FILENAME="${THEME_WALLPAPER_FILENAME}"
TARGET_THEME_USERS="${TARGET_THEME_USERS}"
EOF_THEME_VARS

    # --- PART 2: Dynamic User Creation & Shell Setup ---
    {
        echo ""
        echo "# --- User Configuration ---"

        # Root Account setup logic... [Keep existing root password logic]

        # User Accounts Loop
        for i in "${!USER_NAMES[@]}"; do
            local u="${USER_NAMES[$i]}"
            local p="${USER_PASSWORDS[$i]}"
            local s="${USER_SUDO[$i]}"

            echo "info \"Creating user '$u' and setting up Zsh/OMZ...\""
            echo "useradd -m -s /bin/zsh '$u'"
            echo "echo \"\${USER_NAMES[$i]}:\${USER_PASSWORDS[$i]}\" | chpasswd"
            [[ "$s" == "true" ]] && echo "usermod -aG wheel '$u'"

            # Install Oh My Zsh (Unattended & Silent)
            echo "exec_silent run_with_retry sudo -u '$u' sh -c \"\$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)\" \"\" --unattended"

            # Clone Plugins and Themes
            echo "U_CUSTOM='/home/$u/.oh-my-zsh/custom'"
            echo "run_with_retry sudo -u '$u' git clone --depth=1 https://github.com/romkatv/powerlevel10k.git \"\$U_CUSTOM/themes/powerlevel10k\""
            echo "run_with_retry sudo -u '$u' git clone https://github.com/zsh-users/zsh-autosuggestions \"\$U_CUSTOM/plugins/zsh-autosuggestions\""
            echo "run_with_retry sudo -u '$u' git clone https://github.com/zsh-users/zsh-syntax-highlighting.git \"\$U_CUSTOM/plugins/zsh-syntax-highlighting\""
            echo "run_with_retry sudo -u '$u' git clone https://github.com/Aloxaf/fzf-tab \"\$U_CUSTOM/plugins/fzf-tab\""

            # Handle Powerlevel10k Theme selection
            if [[ "$TTY_THEME_ID" != "none" ]]; then
                echo "info \"Applying p10k theme for $u...\""
                case "$TTY_THEME_ID" in
                    1) echo "run_with_retry curl -fL https://raw.githubusercontent.com/nordtheme/powerlevel10k/master/files/.p10k.zsh -o '/home/$u/.p10k.zsh' || true" ;;
                    2) echo "run_with_retry curl -fL https://raw.githubusercontent.com/dracula/powerlevel10k/master/files/.p10k.zsh -o '/home/$u/.p10k.zsh' || true" ;;
                    3) echo "run_with_retry curl -fL https://raw.githubusercontent.com/sainnhe/gruvbox-material/master/extras/p10k-gruvbox-material-dark.zsh -o '/home/$u/.p10k.zsh' || true" ;;
                    4) echo "run_with_retry curl -fL https://raw.githubusercontent.com/dracula/powerlevel10k/master/files/.p10k.zsh -o '/home/$u/.p10k.zsh' || true" ;; # Monokai fallback
                esac
                echo "if [ -f '/home/$u/.p10k.zsh' ]; then chown '$u:$u' '/home/$u/.p10k.zsh'; fi"
            fi
            # Create final .zshrc
            echo "cat <<'EOF_ZSH' > '/home/$u/.zshrc'
# Enable P10k Instant Prompt
if [[ -r \"\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh\" ]]; then
  source \"\${XDG_CACHE_HOME:-\$HOME/.cache}/p10k-instant-prompt-\${(%):-%n}.zsh\"
fi
typeset -g POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true

[ -f /etc/profile.d/tty-colors.sh ] && source /etc/profile.d/tty-colors.sh
# if [[ -o interactive ]]; then fastfetch; fi
export ZSH=\"\$HOME/.oh-my-zsh\"
ZSH_THEME=\"powerlevel10k/powerlevel10k\"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting fzf-tab)
source \$ZSH/oh-my-zsh.sh
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
alias ls='lsd'
alias ll='lsd -la'
EOF_ZSH"
            echo "chown '$u:$u' '/home/$u/.zshrc'"
        done
    } >> /mnt/configure_chroot.sh

    # --- PART 3: Tail (Sudoers, Pacman, Services) ---
    cat <<CHROOT_TAIL >> /mnt/configure_chroot.sh
info "Configuring sudo for 'wheel' group..."

# SECURITY: Use a drop-in file for temporary NOPASSWD instead of modifying main sudoers
# This way, if the script crashes, the main sudoers is untouched
mkdir -p /etc/sudoers.d
echo "%wheel ALL=(ALL:ALL) NOPASSWD: ALL" > /etc/sudoers.d/99-archinstall-temp
chmod 440 /etc/sudoers.d/99-archinstall-temp
success "Temporary passwordless sudo enabled for installation."

# Also uncomment wheel in main sudoers for post-install (WITH password)
if grep -q -E '^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    sed -i -E 's/^#[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL/%wheel ALL=(ALL:ALL) ALL/' /etc/sudoers
    success "wheel group enabled in sudoers (password required post-install)."
elif grep -q -E '^[[:space:]]*%wheel[[:space:]]+ALL=\(ALL(:ALL)?\)[[:space:]]+ALL' /etc/sudoers; then
    success "'wheel' group already enabled in sudoers."
else
    warn "Could not find wheel group line in sudoers. Manual configuration may be needed."
fi

# Ensure Pacman config (ParallelDownloads, Color, VerbosePkgLists, Multilib)
info "Ensuring Pacman configuration inside chroot..."
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
sed -i -E \
    -e 's/^[[:space:]]*#[[:space:]]*(VerbosePkgLists)/\1/' \
    /etc/pacman.conf
if ! grep -q -E "^[[:space:]]*VerbosePkgLists" /etc/pacman.conf; then
    echo "VerbosePkgLists" >> /etc/pacman.conf
fi

if [[ "\${INSTALL_STEAM}" == "true" ]] || [[ "\${ENABLE_MULTILIB}" == "true" ]]; then
    info "Ensuring Multilib repository is enabled in chroot pacman.conf..."
    sed -i -e '/^#[[:space:]]*\[multilib\]/s/^#//' -e '/^\[multilib\]/{n;s/^[[:space:]]*#[[:space:]]*Include/Include/}' /etc/pacman.conf
    check_status_chroot "Ensuring multilib is enabled in chroot pacman.conf"
fi
success "Pacman configuration verified."

# --- ZRAM CONFIGURATION ---
    if [[ "${SWAP_TYPE}" == "ZRAM" ]]; then
        info "Configuring ZRAM..."
        # Create config file for zram-generator
        cat <<EOF_ZRAM > /etc/systemd/zram-generator.conf
[zram0]
zram-size = min(ram, 8192)
compression-algorithm = zstd
EOF_ZRAM
        check_status_chroot "Creating ZRAM config"
        success "ZRAM configured (Cap: 8GB, Algo: zstd)."
    fi

# --- CONFIGURE MKINITCPIO (Hooks) ---
info "Configuring mkinitcpio hooks..."
if [[ "\${ENABLE_ENCRYPTION}" == "true" ]]; then
    # Add 'encrypt' hook before 'filesystems'
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block encrypt filesystems fsck)/' /etc/mkinitcpio.conf
    info "Added 'encrypt' hook to mkinitcpio.conf"
else
    # Standard hooks
    sed -i 's/^HOOKS=(.*)/HOOKS=(base udev autodetect modconf kms keyboard keymap consolefont block filesystems fsck)/' /etc/mkinitcpio.conf
fi

# Regenerate initramfs
info "Generating initramfs..."
mkinitcpio -P
check_status_chroot "mkinitcpio generation"

# --- FORCE RESOLUTION FOR KMSCON/TTY ---
if [[ "\${ENABLE_TTY_RICE}" == "true" && -n "\${TTY_RES}" ]]; then
    info "Applying resolution \${TTY_RES} to Bootloader..."

    # We target the file directly inside the new system
    if [ -f "/etc/default/grub" ]; then
        # 1. Clear any old video entries
        sed -i 's/video=[^ ]*//g' /etc/default/grub

        # 2. Force the kernel parameter into the DEFAULT line
        # We use & to append right after the opening quote
        sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\"|&video=\${TTY_RES}-32 |" /etc/default/grub

        # 3. Force the GRUB UI resolution
        sed -i "s/^#*GRUB_GFXMODE=.*/GRUB_GFXMODE=\${TTY_RES}x32/" /etc/default/grub

        # 4. Set payload to keep so the kernel doesn't reset resolution
        grep -q "GRUB_GFXPAYLOAD_LINUX" /etc/default/grub || echo "GRUB_GFXPAYLOAD_LINUX=keep" >> /etc/default/grub
        sed -i "s/^#*GRUB_GFXPAYLOAD_LINUX=.*/GRUB_GFXPAYLOAD_LINUX=keep/" /etc/default/grub
    fi

    # systemd-boot support (if entries exist)
    if [ -d "/boot/loader/entries" ]; then
        for entry in /boot/loader/entries/*.conf; do
            sed -i 's/video=[^ ]*//g' "\$entry"
            sed -i "/^options/ s/$/ video=\${TTY_RES}-32/" "\$entry"
        done
    fi
fi

# --- CONFIGURE BOOTLOADER PARAMETERS ---
if [[ "\${ENABLE_ENCRYPTION}" == "true" ]]; then
    # Get UUID of the RAW encrypted partition
    CRYPT_UUID=\$(blkid -s UUID -o value "\${ROOT_PARTITION}")

    # Kernel parameters for GRUB
    # cryptdevice=UUID=<uuid>:cryptroot root=/dev/mapper/cryptroot
    GRUB_CRYPT_PARAMS="cryptdevice=UUID=\${CRYPT_UUID}:cryptroot root=/dev/mapper/cryptroot"

    sed -i "s|^GRUB_CMDLINE_LINUX_DEFAULT=\".*\"|GRUB_CMDLINE_LINUX_DEFAULT=\"loglevel=3 quiet \${GRUB_CRYPT_PARAMS}\"|" /etc/default/grub

    # Kernel parameters for systemd-boot are handled in the install_bootloader function outside chroot
    # but we store them here just in case specific chroot actions need them.
fi

if [[ "\${SELECTED_FS}" == "btrfs" ]]; then
    GRUB_PARAMS="\${GRUB_PARAMS} rootflags=subvol=@"
fi

if [[ "$INSTALL_NVIDIA" == "true" ]]; then
    # Add nvidia-drm.modeset=1 to GRUB (Essential for Wayland/KDE)
    sed -i 's/^GRUB_CMDLINE_LINUX_DEFAULT="/&nvidia-drm.modeset=1 /' /etc/default/grub
fi

info "Enabling NetworkManager service..."
systemctl enable NetworkManager.service
check_status_chroot "Enabling NetworkManager service"
success "NetworkManager enabled."

if [[ "${INSTALL_VMWARE}" == "true" ]]; then
    info "Enabling VMware Tools..."
    systemctl enable vmtoolsd.service
    systemctl enable vmware-vmblock-fuse.service
    success "VMware tools enabled."
fi

if [[ "${INSTALL_QEMU}" == "true" ]]; then
    info "Enabling QEMU Guest Agent..."
    systemctl enable qemu-guest-agent.service
    success "QEMU Agent enabled."
fi

if [[ -n "\${ENABLE_DM}" ]]; then
    info "Enabling Display Manager service (\${ENABLE_DM})..."
    systemctl enable "\${ENABLE_DM}.service"
    check_status_chroot "Enabling \${ENABLE_DM} service"
    success "\${ENABLE_DM} enabled."
    # --- Configure Auto-Login ---
    if [[ -n "\${AUTO_LOGIN_USER}" ]] && [[ -n "\${ENABLE_DM}" ]]; then
        info "Configuring auto-login for user '\${AUTO_LOGIN_USER}'..."

        case "\${ENABLE_DM}" in
            "sddm")
                # SDDM needs the EXACT session filename.

                # Use the explicitly passed session name first
                target_session="${TARGET_SESSION_NAME}"

                # Only auto-detect if config didn't provide a specific session
                if [[ -z "\$target_session" ]]; then
                    # --- PRIORITY CHECK: Look for known DEs explicitly first ---
                    # This prevents picking "openbox.desktop" by mistake when installing LXQt.
                    if [ -f /usr/share/xsessions/lxqt.desktop ]; then
                        target_session="lxqt"
                    elif [ -f /usr/share/wayland-sessions/plasma.desktop ]; then
                        target_session="plasma"
                    elif [ -f /usr/share/xsessions/plasma.desktop ]; then
                        target_session="plasma"
                    fi
                fi

                # --- FALLBACK CHECK: Blind search if nothing above was found ---
                if [[ -z "\$target_session" ]]; then
                    # Safe Mode: Temporarily disable strict error checking for the search
                    set +e
                    set +o pipefail

                    # 1. Try Wayland
                    if [ -d /usr/share/wayland-sessions ]; then
                        target_session=\$(find /usr/share/wayland-sessions -name "*.desktop" 2>/dev/null | head -n 1 | xargs -r basename -s .desktop)
                    fi

                    # 2. Try X11
                    if [[ -z "\$target_session" ]] && [ -d /usr/share/xsessions ]; then
                        target_session=\$(find /usr/share/xsessions -name "*.desktop" 2>/dev/null | head -n 1 | xargs -r basename -s .desktop)
                    fi

                    # Re-enable strict checking
                    set -e
                    set -o pipefail
                fi

                info "Detected SDDM Session: \$target_session"

                # Write the config
                mkdir -p /etc/sddm.conf.d
                {
                    echo "[Autologin]"
                    echo "User=\${AUTO_LOGIN_USER}"
                    echo "Session=\${target_session}"
                    echo "Relogin=false"
                } > /etc/sddm.conf.d/autologin.conf
                ;;

            "gdm")
                # GNOME (GDM)
                if ! grep -q "\[daemon\]" /etc/gdm/custom.conf; then
                    echo "[daemon]" >> /etc/gdm/custom.conf
                fi
                # Remove old settings if they exist to avoid duplication
                sed -i "/AutomaticLogin/d" /etc/gdm/custom.conf
                sed -i "/\[daemon\]/a AutomaticLoginEnable=True\nAutomaticLogin=\${AUTO_LOGIN_USER}" /etc/gdm/custom.conf
                ;;

            "lightdm")
                # XFCE/MATE (LightDM) configuration
                # FIX: Create the 'autologin' group and add the user.
                groupadd -rf autologin
                gpasswd -a "\${AUTO_LOGIN_USER}" autologin

                # FIX: Use a drop-in config file.
                # NOTE: We use \$ (escaped) for variables calculated INSIDE the chroot.

                dm_session_name=""
                if pacman -Qq xfce4-session >/dev/null 2>&1; then dm_session_name="xfce"; fi
                if pacman -Qq mate-session-manager >/dev/null 2>&1; then dm_session_name="mate"; fi

                mkdir -p /etc/lightdm/lightdm.conf.d
                {
                    echo "[Seat:*]"
                    echo "autologin-user=\${AUTO_LOGIN_USER}"
                    # We must escape the $ here so it checks the variable inside the script, not the installer
                    if [[ -n "\$dm_session_name" ]]; then
                        echo "autologin-session=\$dm_session_name"
                    fi
                } > /etc/lightdm/lightdm.conf.d/autologin.conf

                success "Configured LightDM Autologin for user: \${AUTO_LOGIN_USER}"
                ;;
        esac
        success "Auto-login configured for \${ENABLE_DM} (User: \${AUTO_LOGIN_USER})."
    fi
else
    info "No Display Manager to enable (Server install or manual setup selected)."
fi

if pacman -Qs openssh &>/dev/null; then
    info "OpenSSH package found, enabling sshd service..."
    systemctl enable sshd.service
    success "sshd enabled."
fi
if pacman -Q cups &>/dev/null; then
    info "cups package found, enabling cups service..."
    systemctl enable cups.service
    success "cups enabled."
fi
if pacman -Q bluez &>/dev/null; then
    info "bluez package found, enabling bluetooth service..."
    systemctl enable bluetooth.service
    success "bluez enabled."
fi
if pacman -Q libvirt &>/dev/null; then
    info "libvirt package found, enabling libvirtd service..."
    systemctl enable libvirtd.service
    success "libvirtd enabled."
fi

# Enable UFW
if [[ "${INSTALL_UFW}" == "true" ]]; then
    info "Enabling UFW Firewall..."
    systemctl enable ufw.service
    check_status_chroot "Enabling UFW service"
    success "UFW enabled."
fi

# Install Yay (AUR Helper) - Using yay-bin for speed
if [[ "${INSTALL_YAY}" == "true" ]]; then
    info "Installing Yay (AUR Helper)..."

    # 1. Global Optimization (Good for the user later)
    # We set makepkg to use all cores for future AUR builds
    # $(nproc) is fine here without escape, we want it calculated now
    sed -i "s/^#MAKEFLAGS=\"-j2\"/MAKEFLAGS=\"-j$(nproc)\"/" /etc/makepkg.conf

    # 2. Use the first user from USER_NAMES (more reliable than scanning /home)
    start_dir=\$(pwd)
    BUILD_USER="\${USER_NAMES[0]}"

    if [[ -n "\$BUILD_USER" && -d "/home/\$BUILD_USER" ]]; then
        info "Using user '\$BUILD_USER' to install yay-bin..."
        cd "/home/\$BUILD_USER"

        # 3. Clone yay-bin
        run_with_retry sudo -u "\$BUILD_USER" git clone https://aur.archlinux.org/yay-bin.git
        cd yay-bin

        # 4. Package it (FIXED: Escaped \$BUILD_USER and kept it silent)
        exec_silent run_with_retry sudo -u "\$BUILD_USER" makepkg --noconfirm
        check_status_chroot "Packaging yay-bin"

        info "Installing yay-bin package..."
        exec_silent pacman -U --noconfirm *.pkg.tar.zst
        check_status_chroot "Installing yay-bin"

        # Cleanup
        cd ..
        rm -rf yay-bin
        success "Yay installed successfully (Binary version)."
    else
        warn "No non-root user found to build Yay. Skipping installation."
    fi
    # ESCAPED: \$start_dir
    cd "\$start_dir"
fi

# --- EXECUTE CUSTOMIZATION TASKS ---
# Must run after User Creation, Sudo Setup, and Yay Installation

if [[ -f "/root/Base-TTY.sh" ]]; then
    info "Running Base TTY Customization..."
    bash /root/Base-TTY.sh
fi

if [[ -f "/root/Hyprland.sh" ]]; then
    info "Running Hyprland Customization..."
    bash /root/Hyprland.sh
fi

if [[ -f "/root/KDE-Plasma.sh" ]]; then
    info "Running KDE Plasma Customization..."
    bash /root/KDE-Plasma.sh
fi

success "Chroot configuration script finished successfully."
CHROOT_TAIL



    rm -rf /opt/archinstall_themes

    # --- FINAL: SECURITY CLEANUP (Appended to chroot script) ---
    cat <<'EOF_SEC' >> /mnt/configure_chroot.sh

# --- SECURITY CLEANUP ---
# Remove the temporary NOPASSWD drop-in file created during installation
if [ -f /etc/sudoers.d/99-archinstall-temp ]; then
    info "Removing temporary installer sudo privileges..."
    rm -f /etc/sudoers.d/99-archinstall-temp
    success "Sudoers secured (NOPASSWD removed)."
fi

# CRITICAL: Remove chroot environment file which contains plaintext passwords
if [ -f /etc/chroot_env.sh ]; then
    info "Removing temporary chroot environment variables..."
    rm -f /etc/chroot_env.sh
    success "Credential file removed."
fi
EOF_SEC

    check_status "Creating chroot configuration script"
    chmod +x /mnt/configure_chroot.sh
    check_status "Setting execute permissions on chroot script"

    info "Executing configuration script inside chroot environment..."
    arch-chroot /mnt /configure_chroot.sh
    check_status "Executing chroot configuration script"

    info "Removing chroot configuration script..."
    rm /mnt/configure_chroot.sh
    check_status "Removing chroot script"

    success "System configuration inside chroot complete."
}
