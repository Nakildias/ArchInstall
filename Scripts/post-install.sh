#!/bin/bash

#================================================================================#
#           Arch Linux Zsh & Oh My Zsh Setup Script (v7)                         #
#================================================================================#
# This script uses the Oh My Zsh framework to configure Zsh.                     #
# It will:                                                                       #
#   - Install Zsh, Git, Curl, LSD, Fastfetch, FZF, and a Nerd Font.              #
#   - Install Oh My Zsh and necessary plugins/themes (p10k, autosuggestions, etc.#
#================================================================================#

# --- Color Definitions ---
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Helper Functions ---
info_msg() {
    echo -e "${BLUE}INFO: $1${NC}"
}
success_msg() {
    echo -e "${GREEN}SUCCESS: $1${NC}"
}
warn_msg() {
    echo -e "${YELLOW}WARNING: $1${NC}"
}
error_msg() {
    echo -e "${RED}ERROR: $1${NC}"
}

# --- User Interaction ---
ask_user() {
    local prompt="$1"
    local answer
    while true; do
        read -p "$(echo -e "${YELLOW}$prompt [y/N]: ${NC}")" answer
        case ${answer:-N} in
            [Yy]* ) return 0;;
            [Nn]* ) return 1;;
            * ) error_msg "Please answer yes (y) or no (n).";;
        esac
    done
}

# --- Pre-run Checks ---
if [[ $EUID -eq 0 ]]; then
   error_msg "This script must not be run as root."
   exit 1
fi

TARGET_USER=$USER
USER_HOME=$HOME
info_msg "Running setup for user: ${TARGET_USER} (${USER_HOME})"
sudo -v
if [[ $? -ne 0 ]]; then
    error_msg "Failed to acquire sudo privileges."
    exit 1
fi

apply_theme_consistency() {
    # Ask the user which theme they want if not passed as an argument
    local theme_choice
    echo -e "${YELLOW}Select p10k Theme: (dracula/nord/catppuccin/tokyonight/gruvbox)${NC}"
    read -p "Choice: " theme_choice

    local p10k_file="$HOME/.p10k.zsh"
    local zshrc_file="$HOME/.zshrc"

    info_msg "Applying $theme_choice theme and silencing p10k wizard..."

    case "$theme_choice" in
        "dracula")
            curl -L https://raw.githubusercontent.com/dracula/powerlevel10k/master/files/.p10k.zsh -o "$p10k_file"
            echo 'printf "\033]11;#282a36\007"' >> "$zshrc_file"
            ;;
        "nord")
            curl -L https://raw.githubusercontent.com/nordtheme/powerlevel10k/master/files/.p10k.zsh -o "$p10k_file"
            echo 'printf "\033]11;#2e3440\007"' >> "$zshrc_file"
            ;;
        "catppuccin")
            curl -L https://raw.githubusercontent.com/catppuccin/p10k/main/dist/catppuccin_mocha-p10k.zsh -o "$p10k_file"
            echo 'printf "\033]11;#1e1e2e\007"' >> "$zshrc_file"
            ;;
        "tokyonight")
            curl -L https://raw.githubusercontent.com/folke/tokyonight.nvim/main/extras/zsh/tokyonight_night.zsh-theme -o "$p10k_file"
            echo 'printf "\033]11;#1a1b26\007"' >> "$zshrc_file"
            ;;
        "gruvbox")
            curl -L https://raw.githubusercontent.com/sainnhe/gruvbox-material/master/extras/p10k-gruvbox-material-dark.zsh -o "$p10k_file"
            echo 'printf "\033]11;#282828\007"' >> "$zshrc_file"
            ;;
        *)
            warn_msg "No custom p10k file for $theme_choice, manual wizard will trigger."
            return
            ;;
    esac

    # CRITICAL: Suppress the configuration wizard
    # We add this to the top of .zshrc so it is read before the theme loads
    if ! grep -q "POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD" "$zshrc_file"; then
        sed -i '1itypeset -g POWERLEVEL9K_DISABLE_CONFIGURATION_WIZARD=true' "$zshrc_file"
    fi

    success_msg "$theme_choice p10k theme applied and wizard suppressed."
}

# --- Main Functions ---

install_packages() {
    info_msg "Starting package installation section..."
    if ! ask_user "Do you want to install required packages?"; then
        warn_msg "Skipping package installation."
        return
    fi

    local pacman_pkgs=(
        "zsh" "git" "curl" "lsd" "fastfetch" "fzf" "ttf-firacode-nerd"
    )

    info_msg "Installing required packages with pacman..."
    sudo pacman -Syu --needed --noconfirm "${pacman_pkgs[@]}"
    
    info_msg "Rebuilding font cache..."
    sudo fc-cache -fv
    success_msg "Font cache rebuilt."
    info_msg "A Nerd Font (FiraCode) has been installed. ${YELLOW}Remember to set it in your terminal's settings!${NC}"
}

install_omz_and_plugins() {
    info_msg "Installing Oh My Zsh and plugins..."
    if ! ask_user "Do you want to install Oh My Zsh and its plugins?"; then
        warn_msg "Skipping Oh My Zsh installation."
        return
    fi
    
    local omz_dir="$USER_HOME/.oh-my-zsh"
    local omz_custom="$omz_dir/custom"

    if [ ! -d "$omz_dir" ]; then
        info_msg "Installing Oh My Zsh..."
        sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended
        success_msg "Oh My Zsh installed."
    else
        info_msg "Oh My Zsh is already installed."
    fi

    info_msg "Cloning/updating themes and plugins..."
    [[ ! -d "$omz_custom/themes/powerlevel10k" ]] && git clone --depth=1 https://github.com/romkatv/powerlevel10k.git "$omz_custom/themes/powerlevel10k"
    [[ ! -d "$omz_custom/plugins/zsh-autosuggestions" ]] && git clone https://github.com/zsh-users/zsh-autosuggestions "$omz_custom/plugins/zsh-autosuggestions"
    [[ ! -d "$omz_custom/plugins/zsh-syntax-highlighting" ]] && git clone https://github.com/zsh-users/zsh-syntax-highlighting.git "$omz_custom/plugins/zsh-syntax-highlighting"
    [[ ! -d "$omz_custom/plugins/fzf-tab" ]] && git clone https://github.com/Aloxaf/fzf-tab "$omz_custom/plugins/fzf-tab"
    
    success_msg "Oh My Zsh and plugins are set up."
}

##
## 3. Create .zshrc file
##
create_zshrc() {
    info_msg "Creating new .zshrc file..."
    local zshrc_file="$USER_HOME/.zshrc"

    warn_msg "This action will COMPLETELY OVERWRITE your existing ~/.zshrc file."
    if ! ask_user "Are you sure you want to proceed?"; then
        warn_msg "Skipping .zshrc creation."
        return
    fi

    # Create the new .zshrc with fastfetch at the top, as requested.
    cat > "$zshrc_file" <<'EOF'
# ========================================================================
# This .zshrc file was generated by the Arch Linux Setup Script.
# ========================================================================

# Load TTY Theme Colors
[ -f /etc/profile.d/tty-colors.sh ] && source /etc/profile.d/tty-colors.sh

# NOTE: As per user requirement, fastfetch is executed at the top of the file.
# This is an unconventional setup but may be required for specific terminals or configurations
# to ensure proper color rendering and Powerlevel10k compatibility.
if [[ -o interactive ]]; then
  fastfetch -c ~/.config/fastfetch/config.jsonc
fi

# Enable Powerlevel10k instant prompt for faster shell startup.
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# -------------------------------------------------
# OH MY ZSH CONFIGURATION
# -------------------------------------------------

# Path to your Oh My Zsh installation.
export ZSH="$HOME/.oh-my-zsh"

# Set name of the theme to load --- Powerlevel10k
ZSH_THEME="powerlevel10k/powerlevel10k"

# List of plugins that Oh My Zsh will load.
plugins=(
  git
  zsh-autosuggestions
  zsh-syntax-highlighting
  fzf-tab
)

# Source the main Oh My Zsh script to load all settings, plugins, and themes.
source $ZSH/oh-my-zsh.sh

# -------------------------------------------------
# ALIASES & CUSTOM SETTINGS
# -------------------------------------------------

# To customize prompt, run `p10k configure` or edit ~/.p10k.zsh.
# This file is created by the p10k configuration wizard.
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh

# Aliases for LSD (a modern ls replacement).
alias ls='lsd'
alias l='lsd -l'
alias la='lsd -a'
alias lla='lsd -la'
alias lt='lsd --tree'
EOF

    success_msg "New .zshrc file has been created with the specified order."
}

##
## The functions below are unchanged.
##
setup_fastfetch_config() {
    info_msg "Setting up Fastfetch configuration..."
    local config_dir="$USER_HOME/.config/fastfetch"
    local config_file="$config_dir/config.jsonc"

    if [[ -f "$config_file" ]]; then
        if ! ask_user "Fastfetch config already exists. Do you want to overwrite it?"; then
            warn_msg "Skipping Fastfetch configuration."
            return
        fi
    fi

    mkdir -p "$config_dir"
    cat > "$config_file" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.jsonc",
  "logo": { "type": "small", "padding": { "top": 2, "right": 4 }, "color": { "1": "cyan", "2": "blue" } },
  "defaults": { "module": { "keyColor": "purple", "separator": "  " } },
  "modules": [
    { "type": "break", "string": " " },
    { "type": "os", "key": " OS" },
    { "type": "uptime", "key": " Uptime" },
    { "type": "shell", "key": " Shell" },
    { "type": "de", "key": " DE" },
    { "type": "cpu", "key": " CPU" },
    { "type": "gpu", "key": " GPU" },
    { "type": "memory", "key": " RAM", "format": "{1} / {2}" },
    { "type": "disk", "key": " Disk (/)", "format": "{1} / {2}", "folders": ["/"] },
    "break",
  ]
}
EOF
    success_msg "Created a new Fastfetch configuration at $config_file"
}

change_shell() {
    if [[ "$SHELL" == *"zsh"* ]]; then
        info_msg "Your default shell is already Zsh."
        return
    fi
    info_msg "Changing default shell to Zsh..."
    if ask_user "Do you want to set Zsh as your default shell?"; then
        local zsh_path=$(which zsh)
        if [[ -z "$zsh_path" ]]; then error_msg "Could not find zsh executable."; return; fi
        sudo chsh -s "$zsh_path" "$TARGET_USER"
        [[ $? -eq 0 ]] && success_msg "Default shell changed to Zsh." || error_msg "Failed to change shell."
    else
        warn_msg "Skipping shell change."
    fi
}

# --- Script Execution ---
main() {
    echo -e "${BLUE}=======================================================${NC}"
    echo -e "${BLUE}            Arch Linux & Zsh Setup Script   ${NC}"
    echo -e "${BLUE}=======================================================${NC}"
    
    install_packages
    install_omz_and_plugins
    create_zshrc
    setup_fastfetch_config
    apply_theme_consistency
    change_shell

    echo
    success_msg "All tasks are complete!"
    info_msg "Here are the next steps:"
    echo "  1. ${YELLOW}IMPORTANT: Your ~/.zshrc file has been replaced with your specified layout.${NC}"
    echo "  2. Open your terminal's settings and change the font to 'FiraCode Nerd Font'."
    echo "  3. Log out and log back in to start your new Zsh environment and configure p10k."
    echo

    if ask_user "Do you want to log out now to complete the setup?"; then
        info_msg "Logging out..."
        # Try a few methods to log out the user
        pkill -KILL -u "$TARGET_USER" || killall -u "$TARGET_USER" || echo "Please log out manually."
    fi
}

main
