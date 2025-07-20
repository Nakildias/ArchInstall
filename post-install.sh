#!/bin/bash

#================================================================================#
#                  Arch Linux Zsh & Powerlevel10k Setup Script                   #
#================================================================================#
# This script automates the installation and configuration of:                   #
#   - Zsh (Z Shell)                                                              #
#   - Yay (AUR Helper)                                                           #
#   - Powerlevel10k Theme                                                        #
#   - Essential Zsh plugins (autosuggestions, syntax-highlighting, fzf-tab)      #
#   - LSD (modern 'ls' replacement) with aliases                                 #
#   - Fastfetch with a custom configuration                                      #
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
# Ensure script is not run as root
if [[ $EUID -eq 0 ]]; then
   error_msg "This script must not be run as root. Run it as a normal user with sudo privileges."
   exit 1
fi

# Set target user and home directory
TARGET_USER=$USER
USER_HOME=$HOME
info_msg "Running setup for user: ${TARGET_USER} (${USER_HOME})"

# Refresh sudo timestamp
info_msg "Requesting sudo privileges for package installation..."
sudo -v
if [[ $? -ne 0 ]]; then
    error_msg "Failed to acquire sudo privileges. Please run the script again."
    exit 1
fi

# --- Main Functions ---

##
## 1. Package Installation
##
install_packages() {
    info_msg "Starting package installation section..."
    if ! ask_user "Do you want to install required packages?"; then
        warn_msg "Skipping package installation."
        return
    fi

    # Pacman packages
    local pacman_pkgs=(
        "zsh" "git" "base-devel" "lsd" "fastfetch"
        "zsh-autosuggestions" "zsh-syntax-highlighting" "fzf" "fzf-tab"
    )

    info_msg "Updating system and installing packages with pacman..."
    sudo pacman -Syu --needed --noconfirm "${pacman_pkgs[@]}"
    success_msg "Pacman packages installed."

    # Install yay (AUR helper)
    if ! command -v yay &> /dev/null; then
        info_msg "'yay' not found. It will be installed from the AUR."
        if ask_user "Do you want to install 'yay'?"; then
            (
                cd "$USER_HOME" && \
                git clone https://aur.archlinux.org/yay.git && \
                cd yay && \
                makepkg -si --noconfirm && \
                cd .. && \
                rm -rf yay
            )
            success_msg "'yay' has been installed."
        else
            warn_msg "Skipping 'yay' installation. AUR packages will not be installed."
            return
        fi
    else
        info_msg "'yay' is already installed."
    fi

    # AUR packages
    if command -v yay &> /dev/null; then
        local aur_pkgs=("zsh-theme-powerlevel10k-git")
        info_msg "Installing AUR packages with yay..."
        yay -S --needed --noconfirm "${aur_pkgs[@]}"
        success_msg "AUR packages installed."
    fi
}

##
## 2. Zsh Configuration
##
configure_zsh() {
    info_msg "Starting Zsh configuration..."
    if ! ask_user "Do you want to configure .zshrc?"; then
        warn_msg "Skipping .zshrc configuration."
        return
    fi

    local zshrc_file="$USER_HOME/.zshrc"
    touch "$zshrc_file" # Create if it doesn't exist

    # Source Powerlevel10k
    local p10k_source='source /usr/share/zsh-theme-powerlevel10k/powerlevel10k.zsh-theme'
    if ! grep -qF "$p10k_source" "$zshrc_file"; then
        echo -e "\n# Enable Powerlevel10k theme\n$p10k_source" >> "$zshrc_file"
        success_msg "Added Powerlevel10k to .zshrc."
    fi

    # Source Zsh plugins
    local plugins_source=$(cat <<'EOF'

# Source Zsh plugins
source /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh
source /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh
source /usr/share/fzf/fzf-tab/fzf-tab.zsh
EOF
)
    if ! grep -qF "zsh-autosuggestions.zsh" "$zshrc_file"; then
        echo "$plugins_source" >> "$zshrc_file"
        success_msg "Added Zsh plugins to .zshrc."
    fi

    # Add LSD aliases
    local lsd_aliases=$(cat <<'EOF'

# -------------------------------------------------
# ALIASES FOR LSD (Modern ls replacement)
# -------------------------------------------------
alias ls='lsd'
alias l='lsd -l'
alias la='lsd -a'
alias lla='lsd -la'
alias lt='lsd --tree'
EOF
)
    if ! grep -qF "alias ls='lsd'" "$zshrc_file"; then
        echo "$lsd_aliases" >> "$zshrc_file"
        success_msg "Added LSD aliases to .zshrc."
    fi

    # Add fastfetch on startup
    local fastfetch_block=$(cat <<'EOF'

# Run fastfetch on interactive shell startup
if [[ -o interactive ]]; then
  fastfetch -c ~/.config/fastfetch/config.jsonc
fi
EOF
)
    if ! grep -qF "fastfetch -c" "$zshrc_file"; then
        echo "$fastfetch_block" >> "$zshrc_file"
        success_msg "Added fastfetch startup command to .zshrc."
    fi
}

##
## 3. Fastfetch Configuration
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
    
    # Use a heredoc to create the config file
    cat > "$config_file" <<'EOF'
{
  "$schema": "https://github.com/fastfetch-cli/fastfetch/raw/dev/doc/json_schema.jsonc",
  "logo": {
    "type": "kitty-direct",
    "source": "arch_small",
    "color1": "cyan",
    "color2": "blue"
  },
  "display": {
    "separator": "  ->  ",
    "keyWidth": 10
  },
  "modules": [
    "title",
    "separator",
    {
      "type": "os",
      "key": "OS"
    },
    {
      "type": "host",
      "key": "Host"
    },
    {
      "type": "kernel",
      "key": "Kernel"
    },
    {
      "type": "uptime",
      "key": "Uptime"
    },
    {
      "type": "packages",
      "key": "Packages"
    },
    {
      "type": "shell",
      "key": "Shell"
    },
    {
      "type": "de",
      "key": "DE/WM"
    },
    {
      "type": "terminal",
      "key": "Terminal"
    },
    "cpu",
    "gpu",
    "memory",
    {
      "type": "disk",
      "key": "Disk",
      "folders": ["/", "/home"]
    },
    "break",
    "colors"
  ]
}
EOF

    success_msg "Created a new Fastfetch configuration at $config_file"
}

##
## 4. Change Default Shell
##
change_shell() {
    if [[ "$SHELL" == *"zsh"* ]]; then
        info_msg "Your default shell is already Zsh."
        return
    fi
    
    info_msg "Changing default shell to Zsh..."
    if ask_user "Do you want to set Zsh as your default shell?"; then
        local zsh_path
        zsh_path=$(which zsh)
        if [[ -z "$zsh_path" ]]; then
            error_msg "Could not find zsh executable."
            return
        fi
        
        sudo chsh -s "$zsh_path" "$TARGET_USER"
        if [[ $? -eq 0 ]]; then
            success_msg "Default shell changed to Zsh."
        else
            error_msg "Failed to change the default shell."
        fi
    else
        warn_msg "Skipping shell change."
    fi
}


# --- Script Execution ---
main() {
    echo -e "${BLUE}====================================================${NC}"
    echo -e "${BLUE}     Welcome to the Arch Linux Zsh Setup Script   ${NC}"
    echo -e "${BLUE}====================================================${NC}"
    
    install_packages
    configure_zsh
    setup_fastfetch_config
    change_shell

    echo
    success_msg "All tasks are complete!"
    info_msg "Here are the next steps:"
    echo "  1. Log out and log back in to use Zsh as your default shell."
    echo "  2. When you first start Zsh, Powerlevel10k will run its configuration wizard."
    echo "     If it doesn't, you can start it manually by running: ${YELLOW}p10k configure${NC}"
    echo
}

main
