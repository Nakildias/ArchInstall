#!/bin/bash
# Scripts/late-install.sh
# Applies the "ArchInstall" TTY Ricing (Zsh, Tmux, KMSCON, Themes) to an existing Arch Linux system.

# --- COLORS ---
C_OFF='\033[0m'
C_CYAN='\033[1;36m'
C_GREEN='\033[1;32m'
C_RED='\033[1;31m'
C_YELLOW='\033[1;33m'

# --- 0. PRE-FLIGHT CHECK ---
if [ "$EUID" -ne 0 ]; then
  echo -e "${C_RED}❌ Error: This script must be run as root.${C_OFF}"
  exit 1
fi

echo -e "${C_CYAN}>>> ARCHINSTALL LATE-RICE: TTY + SHELL + THEME ENGINE${C_OFF}"
echo "This will configure KMSCON (High-Res TTY), Zsh, Tmux, and Neovim."
echo -e "${C_YELLOW}Warning: This overwrites /etc/zsh and /etc/tmux.conf (backups are made).${C_OFF}"
read -p "Continue? [y/N]: " CONFIRM
if [[ ! "$CONFIRM" =~ ^[yY] ]]; then exit 0; fi

# --- 1. DEPENDENCY CHECKS ---
echo "[-] Checking dependencies..."

# Install official packages first
pacman -S --needed --noconfirm zsh tmux fzf neovim zsh-autosuggestions zsh-syntax-highlighting fastfetch sed grep coreutils ttf-jetbrains-mono-nerd

# Check/Install KMSCON (AUR)
if ! command -v kmscon &> /dev/null; then
    echo -e "${C_YELLOW}[!] KMSCON (AUR) is missing.${C_OFF}"
    
    # Try to find a non-root user to run yay
    POTENTIAL_USER=$(logname 2>/dev/null || echo $SUDO_USER)
    
    if [[ -z "$POTENTIAL_USER" || "$POTENTIAL_USER" == "root" ]]; then
        # List users from /home
        echo "Available users:"
        ls /home
        read -p "Enter a non-root username to install 'kmscon' via yay: " AUR_USER
    else
        read -p "Install 'kmscon' using user '$POTENTIAL_USER'? [Y/n]: " USE_POTENTIAL
        if [[ "$USE_POTENTIAL" =~ ^[nN] ]]; then
            read -p "Enter username: " AUR_USER
        else
            AUR_USER="$POTENTIAL_USER"
        fi
    fi

    if [[ -n "$AUR_USER" ]]; then
        echo "[-] Installing kmscon as $AUR_USER..."
        if sudo -u "$AUR_USER" command -v yay &>/dev/null; then
             sudo -u "$AUR_USER" yay -S --noconfirm kmscon
        else
             echo -e "${C_RED}Error: User '$AUR_USER' does not have 'yay' installed.${C_OFF}"
             echo "Please install 'kmscon' manually (yay -S kmscon) and re-run this script."
             exit 1
        fi
    else
        echo -e "${C_RED}Cannot install AUR package without a user.${C_OFF}"
        exit 1
    fi
fi

# --- 2. THEME ENGINE ---
echo -e "\n${C_YELLOW}>>> THEME SELECTOR <<<${C_OFF}"
echo "1) Nord"
echo "2) Dracula"
echo "3) Gruvbox"
echo "4) Monokai"

read -p "Selection [1-4]: " theme_choice

case $theme_choice in
    1) # Nord
        THEME_COLORS=("2e3440" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "88c0d0" "e5e9f0" "4c566a" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "8fbcbb" "eceff4")
        ;;
    2) # Dracula
        THEME_COLORS=("282a36" "ff5555" "50fa7b" "f1fa8c" "bd93f9" "ff79c6" "8be9fd" "f8f8f2" "6272a4" "ff6e6e" "69ff94" "ffffa5" "d6acff" "ff92df" "a4ffff" "ffffff")
        ;;
    3) # Gruvbox
        THEME_COLORS=("282828" "cc241d" "98971a" "d79921" "458588" "b16286" "689d6a" "a89984" "928374" "fb4934" "b8bb26" "fabd2f" "83a598" "d3869b" "8ec07c" "ebdbb2")
        ;;
    4) # Monokai
        THEME_COLORS=("272822" "f92672" "a6e22e" "f4bf75" "66d9ef" "ae81ff" "a1efe4" "f8f8f2" "75715e" "f92672" "a6e22e" "f4bf75" "66d9ef" "ae81ff" "a1efe4" "f9f8f5")
        ;;
    *) # Default to Nord
        THEME_COLORS=("2e3440" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "88c0d0" "e5e9f0" "4c566a" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "8fbcbb" "eceff4")
        ;;
esac

# --- 3. DUAL-PROTOCOL COLOR GENERATOR ---
# KMSCON needs Xterm codes (\e]4...). Standard TTY needs Linux codes (\e]P...).
echo "[-] Generating color sequences for both protocols..."

LINUX_SEQ=""
XTERM_SEQ=""

for i in {0..15}; do
    COLOR_CODE="${THEME_COLORS[$i]}"

    # Linux VT Protocol: \e]P + Index(Hex) + Color(Hex)
    INDEX_HEX=$(printf '%x' $i)
    LINUX_SEQ="${LINUX_SEQ}\033]P${INDEX_HEX}${COLOR_CODE}"

    # Xterm Protocol: \e]4; + Index(Int) + ;#Color(Hex) + \a
    XTERM_SEQ="${XTERM_SEQ}\033]4;${i};#${COLOR_CODE}\007"
done

# Create the Global Shell Hook
echo "[-] Creating global shell color hook..."
cat <<EOF > /etc/profile.d/tty-colors.sh
#!/bin/sh
# Detect Terminal Type and apply correct sequence
if [ "\$TERM" = "linux" ]; then
    # Standard TTY
    echo -en "${LINUX_SEQ}"
    clear
elif [ "\$TERM" = "xterm-256color" ]; then
    # KMSCON
    echo -en "${XTERM_SEQ}"
    clear
fi
EOF
chmod +x /etc/profile.d/tty-colors.sh

# --- 4. KMSCON & MOUSE CONFIGURATION ---
echo "[-] Configuring KMSCON..."

# Disable GPM (It fights with KMSCON for the mouse)
echo "[-] Disabling GPM to prevent mouse conflict..."
systemctl disable --now gpm 2>/dev/null

mkdir -p /etc/kmscon
cat <<EOF > /etc/kmscon/kmscon.conf
font-name=JetBrainsMono Nerd Font
font-size=12
term=xterm-256color
sb-size=2000
render-engine=gltex
EOF

# Create Service with ROOT permissions (Fixes hanging)
echo "[-] Creating systemd service file..."
cat <<EOF > /etc/systemd/system/kmscon@.service
[Unit]
Description=KMS System Console on %I
Documentation=man:kmscon(1)
After=systemd-user-sessions.service plymouth-quit-wait.service
Conflicts=getty@%i.service gpm.service

[Service]
User=root
Group=root
ExecStart=/usr/bin/kmscon --vt %I --seats seat0 --no-switchvt --config /etc/kmscon/kmscon.conf --login -- /usr/bin/login -p
Restart=always

[Install]
WantedBy=getty.target default.target
EOF

echo "[-] Swapping Getty for KMSCON on TTY1..."
systemctl daemon-reload
systemctl disable --now getty@tty1.service 2>/dev/null
systemctl enable kmscon@tty1.service

# --- 5. TMUX CONFIGURATION ---
echo "[-] Ricing Tmux..."

# Backup existing config if present
if [ -f /etc/tmux.conf ]; then
    mv /etc/tmux.conf "/etc/tmux.conf.bak.$(date +%s)"
    echo "[!] Backed up existing tmux.conf"
fi

cat << 'EOF' > /etc/tmux.conf
# --- CORE ---
set -g mouse off 
unbind -n MouseDown3Pane # Disable right-click menu
set -g default-terminal "xterm-256color"
set -s escape-time 0
set -g base-index 1
setw -g pane-base-index 1

# --- STYLE ---
set -g status-position top
set -g status-justify left
set -g status-style 'bg=color0 fg=color6'
set -g pane-border-style 'fg=color8'
set -g pane-active-border-style 'fg=color6'

# --- STATUS BAR ---
set -g status-left-length 50
set -g status-left "#[bg=color0] "
set -g window-status-format "#[fg=color8,bg=color0] #I "
set -g window-status-current-format "#[fg=color0,bg=color6,bold] #I #[bg=color0] "
set -g status-right-length 100
set -g status-right '#[fg=color4,bg=color0]  #(grep "cpu " /proc/stat | awk "{usage=(\$2+\$4)*100/(\$2+\$4+\$5)} END {print usage \"%\"}") #[fg=color8]| #[fg=color3]%Y-%m-%d #[fg=color8]| #[fg=color6,bold]%H:%M '

# --- KEYS ---
bind -n M-Enter split-window -h -c "#{pane_current_path}"
bind -n M-Space resize-pane -Z
bind -n M-q kill-pane
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D
bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
bind -n M-5 select-window -t 5
bind -n M-6 select-window -t 6
bind -n M-7 select-window -t 7
bind -n M-8 select-window -t 8
bind -n M-9 select-window -t 9
bind -n M-n new-window
bind -n M-r source-file /etc/tmux.conf \; display "Reloaded!"
setw -g mode-keys vi
EOF

# --- 6. ZSH CONFIGURATION ---
echo "[-] Ricing Zsh..."

# Backup existing config if present
if [ -f /etc/zsh/zshrc ]; then
    mv /etc/zsh/zshrc "/etc/zsh/zshrc.bak.$(date +%s)"
    echo "[!] Backed up existing zshrc"
fi

cat << 'EOF' > /etc/zsh/zshrc
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
bindkey -e
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
autoload -U colors && colors

# Apply Colors Hook
if [ -f /etc/profile.d/tty-colors.sh ]; then
    source /etc/profile.d/tty-colors.sh
fi

PROMPT="%B%{$fg[cyan]%}╭─[%{$fg[white]%}%n%{$fg[cyan]%}]──[%{$fg[yellow]%}%~%{$fg[cyan]%}]
%B%{$fg[cyan]%}╰─%{$fg[white]%}➜ %{$reset_color%}"

# Auto-Start Tmux
if [[ -z "$TMUX" ]]; then
    tmux new-session -d -s main 2>/dev/null
    tmux new-window -t main:2 2>/dev/null
    tmux new-window -t main:3 2>/dev/null
    tmux new-window -t main:4 2>/dev/null
    tmux select-window -t main:1 2>/dev/null
    exec tmux attach-session -t main
fi

alias v='nvim'
alias ls='ls --color=auto'
alias ll='ls -la'
EOF

# --- 7. RESOLUTION LOGIC ---
echo -e "\n${C_YELLOW}>>> RESOLUTION SELECTOR <<<${C_OFF}"
echo "Select your monitor's native resolution:"
echo "1) 1920x1080"
echo "2) 2560x1440"
echo "3) 3840x2160"
echo "4) Custom"

read -p "Selection [1-4]: " res_choice
case $res_choice in
    1) RES="1920x1080";;
    2) RES="2560x1440";;
    3) RES="3840x2160";;
    4) read -p "Enter resolution (e.g., 1366x768): " RES;;
    *) RES="1920x1080";;
esac

VIDEO_ARG="video=${RES}-32"
GPU_ARGS=""

if lspci | grep -i "NVIDIA" > /dev/null; then
    GPU_ARGS="nvidia_drm.modeset=1"
elif lspci | grep -i "Intel" > /dev/null; then
    GPU_ARGS="i915.modeset=1"
elif lspci | grep -i "AMD" > /dev/null; then
    GPU_ARGS="amdgpu.modeset=1"
fi

# --- 8. BOOTLOADER CONFIGURATION ---
LOADER_FOUND=false

if [ -d "/boot/loader/entries" ]; then
    LOADER_FOUND=true
    if [ -f "/boot/loader/loader.conf" ]; then
        sed -i "s/^console-mode.*/console-mode max/" /boot/loader/loader.conf || echo "console-mode max" >> /boot/loader/loader.conf
    fi
    ENTRY_FILE=$(ls /boot/loader/entries/*.conf 2>/dev/null | head -n 1)
    if [ ! -z "$ENTRY_FILE" ]; then
        cp "$ENTRY_FILE" "${ENTRY_FILE}.bak"
        # Remove old value if exists
        sed -i "s/video=[^ ]*//g" "$ENTRY_FILE"
        # Add new
        sed -i "/^options/ s/$/ $VIDEO_ARG $GPU_ARGS/" "$ENTRY_FILE"
        echo "Updated systemd-boot entry."
    fi
fi

if [ -f "/etc/default/grub" ]; then
    LOADER_FOUND=true
    cp /etc/default/grub /etc/default/grub.bak
    sed -i '/^GRUB_GFXMODE=/d' /etc/default/grub
    sed -i '/^GRUB_GFXPAYLOAD_LINUX=/d' /etc/default/grub
    echo "GRUB_GFXMODE=${RES}x32" >> /etc/default/grub
    echo "GRUB_GFXPAYLOAD_LINUX=keep" >> /etc/default/grub
    sed -i "s/video=[^ ]*//g" /etc/default/grub
    sed -i "s/GRUB_CMDLINE_LINUX_DEFAULT=\"/GRUB_CMDLINE_LINUX_DEFAULT=\"$VIDEO_ARG $GPU_ARGS /" /etc/default/grub
    grub-mkconfig -o /boot/grub/grub.cfg
    echo "Updated GRUB config."
fi

if [ "$LOADER_FOUND" = false ]; then
    echo "⚠️ No standard bootloader found. Manually add kernel args: $VIDEO_ARG $GPU_ARGS"
fi

# --- 9. EARLY KMS ---
REBUILD_INIT=false
if lspci | grep -i "NVIDIA" > /dev/null && ! grep -q "nvidia" /etc/mkinitcpio.conf; then
    sed -i 's/MODULES=(/MODULES=(nvidia nvidia_modeset nvidia_uvm nvidia_drm /' /etc/mkinitcpio.conf
    REBUILD_INIT=true
fi
if lspci | grep -i "AMD" > /dev/null && ! grep -q "amdgpu" /etc/mkinitcpio.conf; then
    sed -i 's/MODULES=(/MODULES=(amdgpu /' /etc/mkinitcpio.conf
    REBUILD_INIT=true
fi
if lspci | grep -i "Intel" > /dev/null && ! grep -q "i915" /etc/mkinitcpio.conf; then
    sed -i 's/MODULES=(/MODULES=(i915 /' /etc/mkinitcpio.conf
    REBUILD_INIT=true
fi

if [ "$REBUILD_INIT" = true ]; then
    echo "Rebuilding initramfs..."
    mkinitcpio -P
fi

# --- 10. FINISH ---
mkdir -p /etc/xdg/nvim
cat <<EOF > /etc/xdg/nvim/sysinit.vim
set number
set relativenumber
set bg=dark
colorscheme habamax
EOF

cat <<'EOF_TOGGLE_KMS' > /usr/local/bin/toggle-kmscon
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi

# List of known display managers
DMS="ly sddm gdm lightdm lxdm greetd"

stop_all_dms() {
    echo "Stopping all display managers..."
    
    # 1. Stop graphical target (canonical way)
    systemctl stop graphical.target 2>/dev/null
    
    # 2. Force stop each known DM service
    for dm in $DMS; do
        systemctl stop "$dm" 2>/dev/null
        systemctl kill "$dm" 2>/dev/null
    done
    
    # 3. Nuclear: Kill any remaining DM processes directly
    pkill -9 -x ly 2>/dev/null
    pkill -9 -x sddm 2>/dev/null
    pkill -9 -x gdm 2>/dev/null
    pkill -9 -x lightdm 2>/dev/null
    pkill -9 -x greetd 2>/dev/null
    pkill -9 -x Xorg 2>/dev/null
    pkill -9 -x X 2>/dev/null
    
    # 4. Stop getty on tty1 if running
    systemctl stop getty@tty1.service 2>/dev/null
    
    # 5. Wait for TTY to be released
    sleep 2
    
    # 6. Forcefully deallocate TTY1 if still held
    fgconsole 2>/dev/null || true
    deallocvt 1 2>/dev/null || true
}

start_gui() {
    echo "Starting Graphical Interface..."
    
    # Find which DM is enabled and start it, or fall back to graphical.target
    for dm in $DMS; do
        if systemctl is-enabled "$dm" 2>/dev/null | grep -q "enabled"; then
            echo "Starting $dm..."
            systemctl start "$dm"
            return
        fi
    done
    
    # Fallback to graphical target
    systemctl start graphical.target 2>/dev/null || systemctl start getty@tty1.service
}

if systemctl is-active --quiet kmscon@tty1.service; then
    echo "=== Switching: KMSCON -> GUI ==="
    systemctl stop kmscon@tty1.service
    systemctl disable kmscon@tty1.service
    
    # Check if GUI was previously available
    if systemctl list-unit-files graphical.target &>/dev/null; then
        start_gui
    else
        echo "Starting Getty..."
        systemctl start getty@tty1.service
    fi
    echo "Done."
else
    echo "=== Switching: GUI -> KMSCON ==="
    
    # Scorched earth approach to stop everything
    stop_all_dms
    
    # Enable and start KMSCON
    systemctl enable kmscon@tty1.service
    systemctl start kmscon@tty1.service
    
    # Verify it started
    sleep 1
    if systemctl is-active --quiet kmscon@tty1.service; then
        echo "KMSCON is now active on TTY1."
    else
        echo "ERROR: KMSCON failed to start. Check: systemctl status kmscon@tty1"
    fi
fi
EOF_TOGGLE_KMS
chmod +x /usr/local/bin/toggle-kmscon

# Symlink for the name user expected
ln -sf /usr/local/bin/toggle-kmscon /usr/local/bin/kmscon-toggle

# Create Desktop Entry (like Base-TTY.sh does)
cat <<EOF_DESKTOP > /usr/share/applications/kmscon-toggle.desktop
[Desktop Entry]
Name=Toggle KMSCON Terminal
Exec=pkexec /usr/local/bin/toggle-kmscon
Icon=utilities-terminal
Type=Application
Terminal=false
Categories=System;Utility;
EOF_DESKTOP

# Copy to current user's desktop if it exists
CURRENT_USER=$(logname 2>/dev/null || echo $SUDO_USER)
if [[ -n "$CURRENT_USER" && -d "/home/$CURRENT_USER/Desktop" ]]; then
    cp /usr/share/applications/kmscon-toggle.desktop "/home/$CURRENT_USER/Desktop/"
    chmod +x "/home/$CURRENT_USER/Desktop/kmscon-toggle.desktop"
    chown "$CURRENT_USER:$CURRENT_USER" "/home/$CURRENT_USER/Desktop/kmscon-toggle.desktop"
fi

cat <<'EOF_TOGGLE_TMUX' > /usr/local/bin/tmux-toggle
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Run as root."; exit 1; fi

ZSHRC="/etc/zsh/zshrc"

if grep -q "exec tmux" "$ZSHRC"; then
    echo "Disabling Auto-Tmux in /etc/zsh/zshrc..."
    # Comment out the block
    sed -i '/if \[\[ -z "\$TMUX" \]\]; then/,/fi/ s/^/#/' "$ZSHRC"
    echo "Done. Zsh will start normally."
else
    echo "Enabling Auto-Tmux in /etc/zsh/zshrc..."
    # Uncomment the block (naive replace, assumes standard structure)
    sed -i '/#if \[\[ -z "\$TMUX" \]\]; then/,/#fi/ s/^#//' "$ZSHRC"
    # If sed failed (different structure), warn user
    if ! grep -q "exec tmux" "$ZSHRC"; then
        echo "Could not auto-enable. Check $ZSHRC manually."
    else
        echo "Done. Tmux will auto-start."
    fi
fi
EOF_TOGGLE_TMUX
chmod +x /usr/local/bin/tmux-toggle

echo "=========================================="
echo -e "${C_GREEN}    FANCY TTY MODE COMPLETE: REBOOT NOW.${C_OFF}"
echo -e "    New Commands Available:"
echo -e "      ${C_CYAN}kmscon-toggle${C_OFF} : Switch between High-Res and Standard TTY"
echo -e "      ${C_CYAN}tmux-toggle${C_OFF}   : Enable/Disable auto-tmux on login"
echo "=========================================="
