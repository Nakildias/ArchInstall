#!/bin/bash

# --- Interactive Menus ---

# Helper: Print a formatted menu and get selection
# Usage: ask_selection "Title" result_var default_idx "Option 1 | Desc" "Option 2 | Desc" ...
ask_selection() {
    local title="$1"
    local res_var="$2"
    local default_idx="$3"
    shift 3
    local options=("$@")

    echo -e "${C_CYAN}${C_BOLD}:: ${title}${C_OFF}"
    echo ""
    
    local i=1
    for opt in "${options[@]}"; do
        # Split by "|" if present
        local name="${opt%%|*}"
        local desc="${opt#*|}"
        
        # Trim whitespace
        name="$(echo "$name" | xargs)"
        if [[ "$name" == "$desc" ]]; then
            desc=""
        else
            desc="$(echo "$desc" | xargs)"
        fi
        
        if [[ -n "$desc" ]]; then
             printf "   ${C_BOLD}[%d]${C_OFF} %-15s ${C_GREY}(%s)${C_OFF}\n" "$i" "$name" "$desc"
        else
             printf "   ${C_BOLD}[%d]${C_OFF} %s\n" "$i" "$name"
        fi
        ((i++))
    done
    echo ""
    
    local default_val=""
    if [[ -n "$default_idx" ]]; then
       # 1-based index to 0-based
       local d_i=$((default_idx - 1))
       if [[ $d_i -ge 0 && $d_i -lt ${#options[@]} ]]; then
           local raw="${options[$d_i]}"
           default_val="${raw%%|*}"
           default_val="$(echo "$default_val" | xargs)"
       fi
    fi

    local prompt_str="> Selection"
    [[ -n "$default_idx" ]] && prompt_str+=" [${default_idx}]"
    prompt_str+=":"

    while true; do
        echo -e "${C_YELLOW}${C_BOLD}   ${prompt_str}${C_OFF} \c"
        read -r input
        
        # Default
        if [[ -z "$input" && -n "$default_idx" ]]; then
            input="$default_idx"
        fi

        # Validate integer
        if [[ "$input" =~ ^[0-9]+$ ]] && ((input >= 1 && input <= ${#options[@]})); then
             local idx=$((input - 1))
             local choice_raw="${options[$idx]}"
             local choice_final="${choice_raw%%|*}"
             choice_final="$(echo "$choice_final" | xargs)"
             
             printf -v "$res_var" "%s" "$choice_final"
             
             # Visual confirmation
             print_subitem "Selected: ${C_BOLD}${choice_final}${C_OFF}"
             break
        else
             echo -e "     ${C_RED}Invalid selection. Please try again.${C_OFF}"
        fi
    done
}

load_config_profile() {
    local config_dir="./config"
    USE_CONFIG="false"

    # Check if any .conf files exist in the directory
    if [ -d "$config_dir" ] && compgen -G "${config_dir}/*.conf" > /dev/null; then
        mapfile -t config_files < <(ls "${config_dir}"/*.conf)
        
        local options=()
        for f in "${config_files[@]}"; do
             options+=("$(basename "$f")")
        done
        options+=("Interactive Mode")

        local choice=""
        # Ask user to pick a profile
        ask_selection "Select Configuration Profile:" choice 2 "${options[@]}" 

        if [[ "$choice" != "Interactive Mode" ]]; then
             for f in "${config_files[@]}"; do
                 if [[ "$(basename "$f")" == "$choice" ]]; then
                      CONFIG_FILE="$f"
                      print_action "Loading profile: $choice"
                      # Source the file to load variables into the environment
                      source "$CONFIG_FILE"
                      USE_CONFIG="true"
                      break
                 fi
             done
        else
            print_action "Starting Interactive Mode..."
        fi
    fi
}

select_kernel() {
    update_status "Kernel Selection"
    print_header "KERNEL SELECTION"

    if [[ "$USE_CONFIG" == "true" && -n "${SELECTED_KERNEL:-}" ]]; then
        print_action "Using Kernel from config: $SELECTED_KERNEL"
        return
    fi
    
    print_context "The kernel is the core of the operating system."
    print_context "- Linux : Latest stable (Recommended for most)"
    print_context "- LTS   : Long Term Support (Best for servers/stability)"
    print_context "- Zen   : Optimized for desktop/gaming responsiveness"
    echo ""

    local kernels=(
        "linux      | Standard Stable Kernel"
        "linux-lts  | Long Term Support"
        "linux-zen  | Optimized for Gaming/Desktop"
    )
    
    ask_selection "Select your Kernel:" SELECTED_KERNEL 1 "${kernels[@]}"
}

select_bootloader() {
    if [[ "$BOOT_MODE" == "BIOS" ]]; then
        SELECTED_BOOTLOADER="grub"
        update_status "Legacy BIOS detected. Forcing GRUB."
        return
    fi

    # Check for Config
    if [[ "$USE_CONFIG" == "true" && -n "${SELECTED_BOOTLOADER:-}" ]]; then
        print_action "Using Bootloader from config: $SELECTED_BOOTLOADER"
        return
    fi

    update_status "Bootloader Selection"
    print_header "BOOTLOADER SELECTION"
    
    print_context "Choose how your system will start:"
    print_context "- GRUB         : Reliable, themable, and robust. Supports everything."
    print_context "- systemd-boot : Minimalist, ultra-fast. UEFI-only. (Arch Default)"
    echo ""

    local bootloaders=(
        "grub           | Highly Compatible & Themable"
        "systemd-boot   | Fast & Minimalist (UEFI)"
    )
    
    ask_selection "Select a Bootloader:" SELECTED_BOOTLOADER 1 "${bootloaders[@]}"
}

select_desktop_environment() {
    # Disable exit-on-error for this function to prevent crashes during file scanning
    set +e
    set +o pipefail
    
    log_to_file "DEBUG: Entering select_desktop_environment"
    update_status "Desktop Environment"
    print_header "DESKTOP ENVIRONMENT"

    AUTO_LOGIN_USER=""

    # --- PROCEDURAL: Scan Directory for Profiles ---
    local profile_dir="${SCRIPT_DIR}/DE-Profiles"
    log_to_file "DEBUG: Scanning $profile_dir"
    
    if [ ! -d "$profile_dir" ]; then
        error "DE-Profiles directory not found at $profile_dir"
        exit 1
    fi

    # Safer globbing method
    local profile_files=()
    shopt -s nullglob
    for f in "$profile_dir"/*.conf; do
        profile_files+=("$f")
    done
    shopt -u nullglob

    if [ ${#profile_files[@]} -eq 0 ]; then
        error "No DE profiles found in $profile_dir"
        exit 1
    fi

    local options=()
    local file_map=()

    local i=0
    for f in "${profile_files[@]}"; do
        log_to_file "DEBUG: Processing profile: $f"
        
        # Use subshell sourcing to extract variables safely without regex/grep fragility
        local display_name=""
        local description=""
        
        # We assume strict error checking is disabled in this scope as per previous fix
        # Read variables via subshell
        display_name=$( (source "$f" && echo "$DE_PRETTY_NAME") 2>/dev/null )
        description=$( (source "$f" && echo "$DE_DESC") 2>/dev/null )
        # Also get internal DE_NAME for matching config
        local internal_name=$( (source "$f" && echo "$DE_NAME") 2>/dev/null )
        
        local basename_f="$(basename "$f" .conf)"
        if [[ -z "$display_name" ]]; then
             display_name="$basename_f"
        fi
        
        if [[ -n "$description" ]]; then
             options+=("$display_name | $description")
        else
             options+=("$display_name")
        fi
        
        file_map+=("$f")
        
        # Check against loaded config if applicable
        if [[ "$USE_CONFIG" == "true" && -z "${SELECTED_DE_CONFIG:-}" ]]; then
             # Match against SELECTED_DE_NAME (e.g., "KDE Plasma (Full)")
             # We check:
             # 1. The variable DE_NAME inside the file
             # 2. The variable DE_PRETTY_NAME inside the file
             # 3. The filename (basename)
             if [[ "${SELECTED_DE_NAME:-}" == "$internal_name" || \
                   "${SELECTED_DE_NAME:-}" == "$display_name" || \
                   "${SELECTED_DE_NAME:-}" == "$basename_f" ]]; then
                   
                  SELECTED_DE_CONFIG="$f"
                  log_to_file "DEBUG: Auto-selected profile from config: $f"
                  print_action "Using Desktop Profile from config: $display_name"
             fi
        fi
        
        ((i++))
    done

    # Output selection
    local choice_name=""
    
    # Interactive
    if [[ -z "${SELECTED_DE_CONFIG:-}" ]]; then
        print_context "Select a desktop environment to install."
        echo ""
        
        ask_selection "Available Environments:" choice_name "" "${options[@]}"
        
        # Match back
        local found=false
        for ((j=0; j<${#options[@]}; j++)); do
             local opt_raw="${options[$j]}"
             local opt_name="${opt_raw%%|*}"
             opt_name="$(echo "$opt_name" | xargs)"
             
             if [[ "$opt_name" == "$choice_name" ]]; then
                 SELECTED_DE_CONFIG="${file_map[$j]}"
                 found=true
                 break
             fi
        done
        
        if [[ "$found" == "false" ]]; then
            error "Failed to map selection to file."
            exit 1
        fi
        
        # Load profile
    fi

    # Always source the selected profile settings (whether from Config or Interactive)
    # This ensures variables like DE_SESSION_NAME, HAS_GUI_THEMES, and DE_PRETTY_NAME are loaded.
    if [[ -f "${SELECTED_DE_CONFIG:-}" ]]; then
         source "$SELECTED_DE_CONFIG"
         log_to_file "DEBUG: Sourced DE Profile: $SELECTED_DE_CONFIG"
    fi

    # --- Auto-Login Logic ---
    AUTO_LOGIN_USER=""
    if [[ -n "${DE_SESSION_NAME:-}" ]]; then
        local should_enable="false"
        
        # Check Config vs Interactive
        if [[ "$USE_CONFIG" == "true" ]]; then
             if [[ "${ENABLE_AUTO_LOGIN:-}" == "true" ]]; then
                 should_enable="true"
                 print_action "Auto-Login enabled via config."
             fi
        else
             if confirm "Enable Auto-Login? (Logs in automatically without password)"; then
                 should_enable="true"
             fi
        fi

        if [[ "$should_enable" == "true" ]]; then
            # Determine User
            if [[ "$USE_CONFIG" == "true" ]]; then
                # Config Mode: Default to first user as requested
                if [[ ${#USER_NAMES[@]} -gt 0 ]]; then
                    AUTO_LOGIN_USER="${USER_NAMES[0]}"
                    print_subitem "Auto-login user set from config (First User): ${AUTO_LOGIN_USER}"
                else
                    warn "No users found for auto-login."
                fi
            elif [ ${#USER_NAMES[@]} -eq 1 ]; then
                AUTO_LOGIN_USER="${USER_NAMES[0]}"
                print_subitem "Auto-login enabled for user: ${AUTO_LOGIN_USER}"
            else
                print_action "Select user for auto-login:"
                # Use ask_selection for users
                ask_selection "User Account:" AUTO_LOGIN_USER 1 "${USER_NAMES[@]}"
            fi
        fi
    fi

    # Write selection to temp file
    # Ensure DE_DM_SERVICE etc are set (from sourced config)
    cat <<EOF > /tmp/arch_install_dm_choice
DM_SERVICE="${DE_DM_SERVICE:-}"
AUTO_LOGIN_USER="${AUTO_LOGIN_USER}"
TARGET_SESSION_NAME="${DE_SESSION_NAME:-}"
EOF
    log_to_file "DEBUG: Exiting select_desktop_environment"
    
    # Restore strict error checking
    set -e
    set -o pipefail
}

select_kde_theme() {
    if [[ "${HAS_GUI_THEMES:-}" != "true" ]]; then return; fi
    
    print_header "KDE THEME SELECTION"
    
    local theme_dir="${SCRIPT_DIR}/DE-Themes/KDE-Themes" # Ensure absolute path via SCRIPT_DIR if possible, or pwd
    # The original code used "$(pwd)/DE-Themes/...", assuming cwd is root.
    # Better to rely on SCRIPT_DIR
    [ -d "${SCRIPT_DIR}/DE-Themes/KDE-Themes" ] && theme_dir="${SCRIPT_DIR}/DE-Themes/KDE-Themes"
    
    # Safe globbing
    local theme_files=()
    if [ -d "$theme_dir" ]; then
        shopt -s nullglob
        for f in "$theme_dir"/*.knsv; do
            theme_files+=("$f")
        done
        shopt -u nullglob
    fi
    
    if [ ${#theme_files[@]} -eq 0 ]; then
        print_subitem "No themes found."
        return
    fi

    local theme_opts=("None")
    local theme_paths=("None")
    
    for f in "${theme_files[@]}"; do
        theme_opts+=("$(basename "$f")")
        theme_paths+=("$f")
    done
    
    local choice_theme=""
    
    # Check Config First
    if [[ "$USE_CONFIG" == "true" && -n "${SELECTED_THEME_NAME:-}" ]]; then
         # Check if configured theme exists in scanned options
         for opt in "${theme_opts[@]}"; do
             if [[ "$opt" == "$SELECTED_THEME_NAME" ]]; then
                 choice_theme="$SELECTED_THEME_NAME"
                 print_action "Using KDE Theme from config: $choice_theme"
                 break
             fi
         done
         if [[ -z "$choice_theme" ]]; then
             warn "Configured theme '$SELECTED_THEME_NAME' not found available themes."
         fi
    fi

    if [[ -z "$choice_theme" ]]; then
        ask_selection "Select a KDE Theme (Konsave):" choice_theme 1 "${theme_opts[@]}"
    fi
    
    SELECTED_THEME_FILE=""
    if [[ "$choice_theme" != "None" ]]; then
         # Find matching path
         for ((k=0; k<${#theme_opts[@]}; k++)); do
             if [[ "${theme_opts[$k]}" == "$choice_theme" ]]; then
                  SELECTED_THEME_FILE="${theme_paths[$k]}"
                  break
             fi
         done
         
         if [[ -f "$SELECTED_THEME_FILE" ]]; then
             # Parse metadata
             local txt_file="${SELECTED_THEME_FILE%.*}.txt"
             if [ -f "$txt_file" ]; then
                THEME_YAY_DEPS=$(sed -nE 's/.*YAY[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$txt_file")
                wp_val=$(sed -nE 's/.*WALLPAPER[[:space:]]*=[[:space:]]*"([^"]+)".*/\1/p' "$txt_file")
                if [[ -n "$wp_val" ]]; then
                    wp_clean="${wp_val#./}"
                    THEME_WALLPAPER_SRC="$theme_dir/$wp_clean"
                    THEME_WALLPAPER_FILENAME="$(basename "$wp_clean")"
                fi
             fi
         fi
         
         echo ""
         if [[ "$USE_CONFIG" == "true" && -n "${TARGET_THEME_USERS:-}" ]]; then
             # Handle "all" case
             if [[ "${TARGET_THEME_USERS,,}" == "all" ]]; then
                  TARGET_THEME_USERS="${USER_NAMES[*]}"
             fi
             print_action "Applying theme to users: $TARGET_THEME_USERS"
         else
             print_action "Select which user(s) to apply the theme to:"
             local user_opts=("All Users" "${USER_NAMES[@]}")
             ask_selection "Target User:" TARGET_THEME_USERS 1 "${user_opts[@]}"
             [[ "$TARGET_THEME_USERS" == "All Users" ]] && TARGET_THEME_USERS="${USER_NAMES[*]}"
         fi
         
         if [[ "$INSTALL_YAY" != "true" ]]; then
             info "Enabling Yay for theme dependencies."
             INSTALL_YAY="true"
         fi
    fi
}

select_tty_rice_config() {
    print_header "SHELL & TERMINAL"

    # Only ask if not already set (e.g. from config)
    if [[ -z "${ENABLE_TTY_RICE}" ]]; then
        # Default initialization if interactive
        ENABLE_TTY_RICE="false"
        TTY_RES=""
        
        print_context "Customize your TTY (Text Mode) experience."
        if confirm "Install KMSCON (High-resolution, rich-color TTY)?"; then
            ENABLE_TTY_RICE="true"
            echo ""
            local res_opts=("1920x1080" "2560x1440" "3840x2160" "Custom")
            local res_choice=""
            ask_selection "Select Monitor Resolution:" res_choice 1 "${res_opts[@]}"
            
            if [[ "$res_choice" == "Custom" ]]; then
                 prompt "Enter resolution (e.g. 1366x768): " TTY_RES
            else
                 TTY_RES="$res_choice"
            fi
            
            # Enable Yay if needed
            [[ "${INSTALL_YAY:-false}" != "true" ]] && INSTALL_YAY="true"
        fi
    else
        print_action "Using TTY/Rice config: Rice=${ENABLE_TTY_RICE}, Res=${TTY_RES}"
    fi
    
    # Check for theme config
    if [[ -z "${SELECTED_TTY_CONFIG:-}" ]]; then
        echo ""
        print_subitem "Checking for Zsh Themes..."
        local term_dir="${SCRIPT_DIR}/TERM-Themes"
        
        # Globbing instead of mapfile/ls
        local theme_files=()
        if [ -d "$term_dir" ]; then
            shopt -s nullglob
            for f in "$term_dir"/*.conf; do
                theme_files+=("$f")
            done
            shopt -u nullglob
        fi
        
        if [ ${#theme_files[@]} -gt 0 ]; then
             local t_opts=()
             local t_paths=()
             for f in "${theme_files[@]}"; do
                 t_opts+=("$(basename "$f" .conf)")
                 t_paths+=("$f")
             done
             t_opts+=("None (Manual P10k)")
             
             local t_choice=""
             local auto_match_done=false
             
             if [[ "$USE_CONFIG" == "true" && -n "${TTY_THEME_ID:-}" ]]; then
                 # Simple numeric mapping if ID is 1, 2, 3...
                 if [[ "$TTY_THEME_ID" =~ ^[0-9]+$ ]] && (( TTY_THEME_ID <= ${#theme_files[@]} && TTY_THEME_ID > 0 )); then
                      # Adjust for 1-based index to 0-based
                      local idx=$((TTY_THEME_ID - 1))
                      if [[ $idx -ge 0 ]]; then
                          SELECTED_TTY_CONFIG="${theme_files[$idx]}"
                          print_action "Using TTY Theme from config (ID: $TTY_THEME_ID): $(basename "$SELECTED_TTY_CONFIG")"
                          auto_match_done=true
                      fi
                 fi
             fi
             
             if [[ "$auto_match_done" == "false" ]]; then
                 ask_selection "Select Zsh/TTY Theme:" t_choice 1 "${t_opts[@]}"
                 if [[ "$t_choice" != "None (Manual P10k)" ]]; then
                     for ((m=0; m<${#t_opts[@]}; m++)); do
                         if [[ "${t_opts[$m]}" == "$t_choice" ]]; then
                              SELECTED_TTY_CONFIG="${t_paths[$m]}"
                              break
                         fi
                     done
                 fi
             fi
        fi
    fi
}

select_gpu_driver() {
    update_status "GPU Drivers"
    print_header "GPU DRIVERS"
    print_action "Detecting Hardware..."

    INSTALL_NVIDIA="false"
    INSTALL_VMWARE="false"
    INSTALL_QEMU="false"
    
    # Existing lspci logic...
    if ! command -v lspci &>/dev/null; then
         warn "lspci command not found. Cannot auto-detect GPU."
         print_subitem "Assuming standard/Intel graphics."
         return
    fi
    
    # ... rest of function ...
    # Wait, replace_file_content needs contiguous block. 
    # I am replacing select_tty_rice_config, I must output until select_gpu_driver starts or ends?
    # The snippet ends at select_gpu_driver's early return. 
    # I will just include the start of Select_gpu_driver to bind it properly.
    
    if lspci | grep -i "NVIDIA" >/dev/null; then
        warn "NVIDIA GPU detected. Enabling proprietary drivers."
        INSTALL_NVIDIA="true"
    elif lspci | grep -i "VMware" >/dev/null; then
        print_subitem "VMware Virtual GPU detected."
        INSTALL_VMWARE="true"
    elif lspci | grep -i "Red Hat" >/dev/null || lspci | grep -i "Virtio GPU" >/dev/null; then
        print_subitem "QEMU/KVM Virtual GPU detected."
        INSTALL_QEMU="true"
    else
        print_subitem "No special GPU detected (Intel/AMD/Standard)."
    fi
}

select_optional_packages() {
    update_status "Optional Packages"
    print_header "OPTIONAL PACKAGES"

    # Initialize defaults ONLY if unset (interactive mode or missing config)
    : "${INSTALL_STEAM:=false}"
    : "${INSTALL_DISCORD:=false}"
    : "${ENABLE_MULTILIB:=false}"
    : "${INSTALL_UFW:=false}"
    : "${INSTALL_YAY:=false}"
    : "${INSTALL_ZSH:=false}"
    
    # If using config, we skip asking unless vars are missing
    # But to be safe, we check if they were set "explicitly" by the config loading.
    # The simplest check is: if USE_CONFIG is true, assume variables are authoritative.
    
    if [[ "$USE_CONFIG" == "true" ]]; then
        print_action "Using optional packages from config:"
        print_subitem "Gaming (Steam): $INSTALL_STEAM"
        print_subitem "Firewall (UFW): $INSTALL_UFW"
        print_subitem "AUR (Yay): $INSTALL_YAY"
        print_subitem "Shell (Zsh): $INSTALL_ZSH"
        return
    fi
    
    # Interactive Prompts
    
    # Gaming
    if confirm "Install Gaming Essentials? (Steam, Discord, Multilib)"; then
        INSTALL_STEAM=true
        INSTALL_DISCORD=true
        ENABLE_MULTILIB=true
        print_subitem "Gaming Essentials enabled."
    fi

    # Firewall
    if confirm "Install and Enable Firewall (UFW)?"; then
        INSTALL_UFW=true
        print_subitem "UFW enabled."
    fi

    # Yay
    if confirm "Install Yay (AUR Helper)?"; then
        INSTALL_YAY=true
        print_subitem "Yay enabled."
    fi

    # Zsh
    if confirm "Install Zsh Shell?"; then
        INSTALL_ZSH=true
        print_subitem "Zsh enabled."
    fi
}

ask_kexec_preference() {
    update_status "Experimental Boot"
    print_header "FINAL CONFIGURATION"
    print_context "Experimental 'No-Reboot' Startup"
    
    # Check config
    if [[ "$USE_CONFIG" == "true" ]]; then
         : "${ENABLE_KEXEC:=false}"
         print_action "Using Kexec preference from config: ${ENABLE_KEXEC}"
    else
        ENABLE_KEXEC="false"
        if confirm "Enable 'Boot without Restart' (kexec)?"; then
            ENABLE_KEXEC="true"
            print_subitem "Kexec enabled."
        fi
    fi
}

select_mirror_preference() {
    print_action "Mirror Configuration"
    
    if [[ "$USE_CONFIG" == "true" ]]; then
         : "${USE_LOCAL_MIRROR:=false}"
         : "${LOCAL_MIRROR_URL:=""}"
         
         # Allow config to explicitly request interactive mirror selection
         if [[ "$USE_LOCAL_MIRROR" == "ask" || "$USE_LOCAL_MIRROR" == "interactive" ]]; then
             # Reset to force interactive logic below
             USE_CONFIG="false"
         elif [[ "$USE_LOCAL_MIRROR" == "true" ]]; then
             print_subitem "Using Local Mirror: ${LOCAL_MIRROR_URL}"
         else
             print_subitem "Using automatic mirror selection (Reflector)."
         fi
    fi

    if [[ "$USE_CONFIG" != "true" ]]; then
        USE_LOCAL_MIRROR="false"
        LOCAL_MIRROR_URL=""
        if confirm "Use local mirror? (e.g. for caching servers)"; then
            local input_url=""
            local is_retry=false
            while true; do
                if [[ "$is_retry" == "true" ]]; then
                     print_subitem "Previous attempt: ${input_url}"
                fi

                # Standard prompt - strictly uses read -r without readline -e quirks
                prompt "Enter local mirror URL (e.g. http://192.168.1.104:8000/):" input_url

                # Normalize empty input
                input_url="$(echo "$input_url" | xargs)"

                # Basic Format Validation
                if [[ -z "$input_url" ]]; then
                    error "URL cannot be empty."
                    continue
                fi

                print_action "Validating mirror connectivity..."
                if curl --head --connect-timeout 3 --fail "$input_url" &>/dev/null; then
                    print_subitem "Mirror validated successfully."
                    LOCAL_MIRROR_URL="${input_url%/}"
                    USE_LOCAL_MIRROR="true"
                    break
                else
                    error "Mirror unreachable or invalid (Curl failed)."
                    is_retry=true
                    if ! confirm "Mirror is not working. Try again? (No to cancel local mirror)"; then
                        warn "Falling back to automatic selection."
                        USE_LOCAL_MIRROR="false"
                        break
                    fi
                    # Loop continues, effectively asking for input again
                fi
            done
        else
            print_subitem "Using automatic mirror selection (Reflector)."
        fi
    fi
}

exit_menu() {
    print_header "POST-INSTALL ACTIONS"
    
    local choice=""
    local options=(
        "Exit Install Script"
        "Reboot System"
        "Read Logs (nano)"
    )
    
    ask_selection "What would you like to do?" choice 1 "${options[@]}"
    
    case "$choice" in
        "Exit Install Script")
            print_action "Exiting..."
            ;;
        "Reboot System")
            print_action "Rebooting..."
            reboot
            ;;
        "Read Logs (nano)")
            local log_path="${LOG_FILE}"
            if [[ -f "./installer.logs" ]]; then log_path="./installer.logs"; fi
            
            if command -v nano &>/dev/null && [[ -f "$log_path" ]]; then
                nano "$log_path"
            else
                less "$log_path"
            fi
            
            # Recurse
            exit_menu
            ;;
    esac
}
