#!/bin/bash
# Customizers/Base-TTY.sh
# Handles KMSCON, TTY Colors, Tmux, and Zsh Ricing

# Source shared environment (variables + functions)
if [ -f /etc/chroot_env.sh ]; then
    source /etc/chroot_env.sh
fi

info "Starting Base TTY Customization (Updated)..."

if [[ "${ENABLE_TTY_RICE}" == "true" ]]; then
    KMSCON_INSTALLED=false 

    # 1. Improved KMSCON Install Logic
    if command -v yay &> /dev/null && [[ -n "$BUILD_USER" ]]; then
        info "Attempting to install KMSCON from AUR..."
        # Installing KMSCON and diagnostic tools (libinput, usbutils)
        # Installing KMSCON and GPM (Mouse for standard TTY)
        exec_silent run_with_retry sudo -u "$BUILD_USER" bash -c "cd /home/$BUILD_USER && yay -S --noconfirm --needed kmscon libinput gpm usbutils"

        if [ ! -f "/usr/bin/kmscon" ]; then
            error "KMSCON failed to install. Reverting to standard TTY to prevent boot hang."
            KMSCON_INSTALLED=false
        else
            success "KMSCON installed successfully."
            KMSCON_INSTALLED=true
        fi
    fi

    # 2. Check if T_COLORS are loaded
    if [ ${#T_COLORS[@]} -eq 0 ]; then
        warn "No theme colors loaded. Defaulting to Nord."
        # Default Nord
        T_COLORS=("2e3440" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "88c0d0" "e5e9f0" "4c566a" "bf616a" "a3be8c" "ebcb8b" "81a1c1" "b48ead" "8fbcbb" "eceff4")
    fi

    # 3. Generate sequences for BOTH Linux TTY and Xterm (kmscon)
    L_SEQ=""
    X_SEQ=""
    for i in {0..15}; do
        COLOR="${T_COLORS[$i]}"
        HEX_VAL=$(printf '%x' $i)
        L_SEQ="${L_SEQ}\033]P${HEX_VAL}${COLOR}"
        X_SEQ="${X_SEQ}\033]4;${i};#${COLOR}\007"
    done

    # 4. Create the profile hook
    cat <<EOF_COLORS > /etc/profile.d/tty-colors.sh
#!/bin/sh
if [ "\$TERM" = "linux" ]; then
    printf "%b" "${L_SEQ}"
else
    printf "%b" "${X_SEQ}"
fi
clear
EOF_COLORS
    chmod +x /etc/profile.d/tty-colors.sh

    # 5. KMSCON Config & Service
    if [ "$KMSCON_INSTALLED" = true ]; then
        mkdir -p /etc/kmscon
        echo -e "font-name=JetBrainsMono Nerd Font\nfont-size=12\nterm=xterm-256color\nsb-size=2000\nrender-engine=gltex" > /etc/kmscon/kmscon.conf

        cat <<EOF_SVC > /etc/systemd/system/kmscon@.service
[Unit]
Description=KMS System Console on %I
After=systemd-user-sessions.service plymouth-quit-wait.service
Conflicts=getty@%i.service gpm.service
[Service]
User=root
Group=root
ExecStart=/usr/bin/kmscon --vt %I --seats seat0 --no-switchvt --config /etc/kmscon/kmscon.conf --login -- /usr/bin/login -p
Restart=always
[Install]
WantedBy=getty.target default.target
EOF_SVC

        # Toggle Logic
        if [[ -n "${ENABLE_DM}" ]]; then
            info "Desktop Environment detected. Disabling KMSCON on boot for manual toggle."
            systemctl disable kmscon@tty1.service

            cat <<'EOF_SWITCH' > /usr/local/bin/toggle-kmscon
#!/bin/bash
if systemctl is-active --quiet kmscon@tty1.service; then
    systemctl stop kmscon@tty1.service
    systemctl start graphical.target
else
    systemctl stop graphical.target
    systemctl start kmscon@tty1.service
fi
EOF_SWITCH
            chmod +x /usr/local/bin/toggle-kmscon

            # Desktop Entry
            mkdir -p /usr/share/applications
            cat <<EOF_DESKTOP > /usr/share/applications/kmscon-toggle.desktop
[Desktop Entry]
Name=Toggle KMSCON Terminal
Exec=pkexec /usr/local/bin/toggle-kmscon
Icon=utilities-terminal
Type=Application
Terminal=false
Categories=System;Utility;
EOF_DESKTOP

            # Copy to user desktops
            for user_name in "${USER_NAMES[@]}"; do
                user_desktop="/home/${user_name}/Desktop"
                mkdir -p "$user_desktop"
                cp /usr/share/applications/kmscon-toggle.desktop "$user_desktop/"
                chown -R "${user_name}:${user_name}" "$user_desktop"
                chmod +x "${user_desktop}/kmscon-toggle.desktop"
            done
        else
            info "No DE detected. KMSCON will be primary."
            systemctl enable kmscon@tty1.service
        fi


        
# Helper to switch to Standard TTY (Getty)
cat <<'EOF_STD' > /usr/local/bin/use-standard-tty
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi
echo "Switching to Standard TTY (Getty)..."
systemctl stop kmscon@tty1.service 2>/dev/null
systemctl disable kmscon@tty1.service 2>/dev/null
systemctl enable getty@tty1.service
systemctl start getty@tty1.service
# Enable GPM for mouse support
systemctl enable --now gpm
echo "Done. You may need to press Enter or Ctrl+Alt+F1."
EOF_STD
        chmod +x /usr/local/bin/use-standard-tty

        # Helper to switch to KMSCON
        cat <<'EOF_KMS' > /usr/local/bin/use-kmscon
#!/bin/bash
if [ "$EUID" -ne 0 ]; then echo "Please run as root"; exit 1; fi
echo "Switching to KMSCON..."
systemctl stop getty@tty1.service 2>/dev/null
systemctl disable getty@tty1.service 2>/dev/null
systemctl enable kmscon@tty1.service
systemctl start kmscon@tty1.service
# KMSCON conflicts with GPM, so systemd will stop GPM automatically.
echo "Done."
EOF_KMS
        chmod +x /usr/local/bin/use-kmscon

        # Helper to toggle Tmux Autostart
        cat <<'EOF_TOGGLE' > /usr/local/bin/tmux-toggle
#!/bin/bash
CONFIG_FILE="$HOME/.config/no-tmux-autostart"

if [ -f "$CONFIG_FILE" ]; then
    rm "$CONFIG_FILE"
    echo "Tmux auto-start ENABLED."
else
    mkdir -p "$(dirname "$CONFIG_FILE")"
    touch "$CONFIG_FILE"
    echo "Tmux auto-start DISABLED."
fi
EOF_TOGGLE
        chmod +x /usr/local/bin/tmux-toggle

        systemctl disable getty@tty1.service 2>/dev/null || true
    else
        warn "KMSCON not installed. Skipping KMSCON configuration."
        systemctl enable getty@tty1.service
        # Enable GPM for standard TTY mouse support
        systemctl enable --now gpm 2>/dev/null || true
    fi

    # 7. Dynamic Tmux Configuration
    TMUX_BG="#${T_COLORS[0]}"
    TMUX_FG="#${T_COLORS[6]}"
    TMUX_SEC="#${T_COLORS[8]}"
    TMUX_ALT="#${T_COLORS[4]}"

    cat << 'EOF_TMUX' > /etc/tmux.conf
# --- CORE SETTINGS ---
set -g history-limit 10000
set -g mouse off
unbind -n MouseDown3Pane
set -g default-terminal "xterm-256color"
set -ag terminal-overrides ",xterm-256color:RGB"
set -s escape-time 0
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on
set -g set-titles on

# --- STYLE ---
set -g status-interval 2
set -g status-position top
set -g status-style 'bg=default'
set -g pane-border-style 'fg=PLACE_SEC'
set -g pane-active-border-style 'fg=PLACE_FG'

# --- STATUS BAR ---
set -g status-left-length 60
set -g status-left "#[fg=PLACE_FG,bg=PLACE_BG,bold] #S #[bg=default] "
set -g window-status-current-format "#[fg=PLACE_BG,bg=PLACE_FG,bold] #I: #W #[default]"
set -g window-status-format "#[fg=PLACE_SEC,bg=PLACE_BG] #I: #W "

# Enhanced Status Right (Integers and specific MB format)
set -g status-right '#[fg=PLACE_ALT]  #(grep "cpu " /proc/stat | awk "{usage=(\$2+\$4)*100/(\$2+\$4+\$5)} END {printf \"%%.0f%%%%\", usage}") #[fg=PLACE_SEC]| #[fg=PLACE_FG]  #(free -m | awk "/^Mem/ {print \$3 \"MB / \" \$2 \"MB\"}") #[fg=PLACE_SEC]| #[fg=PLACE_FG,bold] %H:%M '

# --- KEYBINDINGS (2-KEY SHORTCUTS) ---

# 1. Tile/Split Subwindows (Subwindow = Pane)
bind -n M-v split-window -h -c "#{pane_current_path}"  # Alt+v for Vertical split
bind -n M-h split-window -v -c "#{pane_current_path}"  # Alt+h for Horizontal split

# 2. Change Subwindow (Alt + Arrow Keys)
bind -n M-Left select-pane -L
bind -n M-Right select-pane -R
bind -n M-Up select-pane -U
bind -n M-Down select-pane -D

# 3. Change Window (Tab) (Alt + Shift + Arrow Keys)
bind -n M-S-Left previous-window
bind -n M-S-Right next-window

# 4. General Management
bind -n M-q kill-pane
bind -n M-n new-window
bind -n M-r source-file /etc/tmux.conf \; display "Reloaded!"

# 5. Direct Access
bind -n M-1 select-window -t 1
bind -n M-2 select-window -t 2
bind -n M-3 select-window -t 3
bind -n M-4 select-window -t 4
EOF_TMUX

    sed -i "s|PLACE_BG|${TMUX_BG}|g" /etc/tmux.conf
    sed -i "s|PLACE_FG|${TMUX_FG}|g" /etc/tmux.conf
    sed -i "s|PLACE_SEC|${TMUX_SEC}|g" /etc/tmux.conf
    sed -i "s|PLACE_ALT|${TMUX_ALT}|g" /etc/tmux.conf

    # 8. Dynamic Zsh Configuration
    ZSH_CYAN="#${T_COLORS[6]}"
    ZSH_YELLOW="#${T_COLORS[3]}"
    ZSH_WHITE="#${T_COLORS[7]}"

    cat << 'EOF_ZSH' > /etc/zsh/zshrc
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
bindkey -e
HISTFILE=~/.zsh_history
HISTSIZE=10000
SAVEHIST=10000
setopt appendhistory
autoload -U colors && colors

[ -f /etc/profile.d/tty-colors.sh ] && source /etc/profile.d/tty-colors.sh

# Themed Prompt using hex placeholders
PROMPT="%B%F{PLACE_CYAN}╭─[%F{PLACE_WHITE}%n%F{PLACE_CYAN}]──[%F{PLACE_YELLOW}%~%F{PLACE_CYAN}]
%B%F{PLACE_CYAN}╰─%F{PLACE_WHITE}➜ %f%b"

alias v='nvim'
alias ls='ls --color=auto'
alias ll='ls -la'

# Ensure Tmux gets these Alt keys instead of the shell
bindkey -r "^[v"
bindkey -r "^[h"

# Auto-Start Tmux (Single Window)
# Skipped if:
# 1. Already in tmux ($TMUX set)
# 2. In vscode terminal
# 3. User has disabled it (~/.config/no-tmux-autostart exists)
if [[ -z "$TMUX" && "$TERM" != "vscode" && ! -f "$HOME/.config/no-tmux-autostart" ]]; then
    tmux new-session -d -s main 2>/dev/null
    exec tmux attach-session -t main
fi
EOF_ZSH

    sed -i "s|PLACE_CYAN|${ZSH_CYAN}|g" /etc/zsh/zshrc
    sed -i "s|PLACE_WHITE|${ZSH_WHITE}|g" /etc/zsh/zshrc
    sed -i "s|PLACE_YELLOW|${ZSH_YELLOW}|g" /etc/zsh/zshrc

    mkdir -p /etc/xdg/nvim
    echo -e "set number\nset relativenumber\nset bg=dark\ncolorscheme habamax" > /etc/xdg/nvim/sysinit.vim

    success "Base TTY Customization (KMSCON/Tmux/Zsh) Complete."
fi
