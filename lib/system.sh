#!/bin/bash

# --- Network Time Sync &System Checks & Timezone ---

sync_time_and_timezone() {
    print_action "Synchronizing system time and timezone..."

    # 1. Enable NTP to sync clock with internet servers
    if command -v timedatectl >/dev/null 2>&1; then
        timedatectl set-ntp true
        print_subitem "NTP synchronization enabled."
    else
        warn "timedatectl not found, skipping NTP sync."
    fi

    # 2. Automatic Timezone Detection (using ipinfo.io)
    # This matches the logic already present in your select_timezone function
    local auto_tz
    auto_tz=$(curl -fsSL --connect-timeout 5 https://ipinfo.io/timezone 2>/dev/null)

    if [[ -n "$auto_tz" && "$auto_tz" == *"/"* ]]; then
        DEFAULT_REGION="${auto_tz%/*}"
        DEFAULT_CITY="${auto_tz#*/}"
        
        # Apply detected timezone to the live environment
        ln -sf "/usr/share/zoneinfo/${auto_tz}" /etc/localtime
        print_subitem "Auto-detected and applied timezone: ${auto_tz}"
    else
        warn "Could not detect timezone automatically. Falling back to manual selection later."
    fi
}

select_locale() {
    print_header "LOCALE & KEYMAP"
    
    # Check config first
    if [[ "$USE_CONFIG" == "true" && -n "${SYSTEM_LOCALE:-}" && -n "${SYSTEM_KEYMAP:-}" ]]; then
        print_action "Using Locale from config: ${SYSTEM_LOCALE}"
        print_subitem "Keymap: ${SYSTEM_KEYMAP}"
        return
    fi
    
    # Default values
    SYSTEM_LOCALE="${SYSTEM_LOCALE:-en_US.UTF-8}"
    SYSTEM_KEYMAP="${SYSTEM_KEYMAP:-us}"
    
    # Quick confirmation for US users
    if confirm "Use default locale (US English, US Keyboard)?"; then
        SYSTEM_LOCALE="en_US.UTF-8"
        SYSTEM_KEYMAP="us"
        print_subitem "Locale: ${SYSTEM_LOCALE}, Keymap: ${SYSTEM_KEYMAP}"
        return
    fi
    
    # Locale selection
    local locale_options=(
        "en_US.UTF-8  | English (United States)"
        "en_GB.UTF-8  | English (United Kingdom)"
        "en_CA.UTF-8  | English (Canada)"
        "fr_CA.UTF-8  | French (Canada)"
        "fr_FR.UTF-8  | French (France)"
        "de_DE.UTF-8  | German (Germany)"
        "es_ES.UTF-8  | Spanish (Spain)"
        "it_IT.UTF-8  | Italian (Italy)"
        "pt_BR.UTF-8  | Portuguese (Brazil)"
        "ru_RU.UTF-8  | Russian (Russia)"
        "ja_JP.UTF-8  | Japanese (Japan)"
        "zh_CN.UTF-8  | Chinese (Simplified)"
        "ko_KR.UTF-8  | Korean (Korea)"
        "Other        | Enter manually"
    )
    
    local locale_choice=""
    ask_selection "Select your Locale:" locale_choice 1 "${locale_options[@]}"
    
    # Extract locale code (before the |)
    local selected_locale
    selected_locale=$(echo "$locale_choice" | awk -F'|' '{print $1}' | xargs)
    
    if [[ "$selected_locale" == "Other" ]]; then
        prompt "Enter locale (e.g., nl_NL.UTF-8):" SYSTEM_LOCALE
    else
        SYSTEM_LOCALE="$selected_locale"
    fi
    
    # Keymap selection
    local keymap_options=(
        "us      | US (QWERTY)"
        "uk      | UK (QWERTY)"
        "cf      | Canadian French"
        "de      | German (QWERTZ)"
        "fr      | French (AZERTY)"
        "es      | Spanish"
        "it      | Italian"
        "br      | Brazilian Portuguese"
        "ru      | Russian"
        "jp106   | Japanese"
        "Other   | Enter manually"
    )
    
    local keymap_choice=""
    ask_selection "Select your Keyboard Layout:" keymap_choice 1 "${keymap_options[@]}"
    
    # Extract keymap code
    local selected_keymap
    selected_keymap=$(echo "$keymap_choice" | awk -F'|' '{print $1}' | xargs)
    
    if [[ "$selected_keymap" == "Other" ]]; then
        prompt "Enter keymap (e.g., dvorak, colemak):" SYSTEM_KEYMAP
    else
        SYSTEM_KEYMAP="$selected_keymap"
    fi
    
    print_subitem "Locale: ${SYSTEM_LOCALE}, Keymap: ${SYSTEM_KEYMAP}"
}

check_boot_mode() {
    print_action "Checking boot mode..."
    if [ -d "/sys/firmware/efi/efivars" ]; then
        BOOT_MODE="UEFI"
        print_subitem "System booted in UEFI mode."
    else
        BOOT_MODE="BIOS"
        print_subitem "System booted in Legacy BIOS mode."
        warn "Legacy BIOS mode detected. Installation will use GPT with BIOS boot settings."
    fi
}

check_internet() {
    print_action "Checking internet connectivity..."
    ARCH_WEBSITE_REACHABLE="true"

    if curl -I --connect-timeout 3 -s https://archlinux.org &>/dev/null; then
        print_subitem "Connection to archlinux.org verified."
    else
        warn "Could not reach archlinux.org."
        print_subitem "Checking fallback connectivity (google.com)..."
        if curl -I --connect-timeout 3 -s https://google.com &>/dev/null; then
            ARCH_WEBSITE_REACHABLE="false"
            warn "Internet is reachable, but archlinux.org is down."
            warn "Some features (like automatic mirror selection with reflector) may require archlinux.org."
            if ! confirm "Do you want to proceed anyway? (Reflector will be skipped)"; then
                print_action "Installation aborted by user."
                exit 1
            fi
        else
            error "No internet connection detected (checked archlinux.org and google.com)."
            exit 1
        fi
    fi
}

select_timezone() {
    update_status "Step 3/12: Localization"
    print_header "LOCALIZATION"
    
    # MODIFIED: Check config
    if [[ "$USE_CONFIG" == "true" && -n "${DEFAULT_REGION:-}" && -n "${DEFAULT_CITY:-}" ]]; then
        print_action "Using Timezone from config: ${DEFAULT_REGION}/${DEFAULT_CITY}"
        return
    fi

    print_action "Attempting to detect your timezone automatically..."

    # 1. Try to get the timezone string (e.g., America/Toronto)
    AUTO_TZ=$(curl -fsSL --connect-timeout 5 https://ipinfo.io/timezone)

    if [[ -n "$AUTO_TZ" && "$AUTO_TZ" == *"/"* ]]; then
        DETECTED_REGION="${AUTO_TZ%/*}"
        DETECTED_CITY="${AUTO_TZ#*/}"

        # 2. Ask for confirmation with the explicit [y/N]
        if confirm "I detected your timezone as ${DETECTED_REGION}/${DETECTED_CITY}. Is this correct?"; then
            DEFAULT_REGION="$DETECTED_REGION"
            DEFAULT_CITY="$DETECTED_CITY"
            print_subitem "Timezone set to ${DEFAULT_REGION}/${DEFAULT_CITY}"
            return 0
        fi
    fi

    # 3. Fallback to manual selection
    warn "Automatic detection skipped. Manual selection required."

    local regions=("America" "Europe" "Asia" "Australia" "Africa")
    local region_choice=""
    ask_selection "Select your Region:" region_choice 1 "${regions[@]}"
    DEFAULT_REGION="$region_choice"

    prompt "Enter your City (e.g., New_York, London, Berlin): " USER_CITY
    # Replace spaces with underscores for the filesystem path
    DEFAULT_CITY=$(echo "$USER_CITY" | sed 's/ /_/g')
}

# Blocks until internet connectivity is restored (with timeout)
wait_for_internet() {
    local host="https://archlinux.org"
    local fallback="https://google.com"
    local max_retries=60  # 5 minutes (60 * 5 seconds)
    local retries=0
    
    # Quick check first
    if curl -I --connect-timeout 3 -s "$host" &>/dev/null; then
        return 0
    fi
    
    warn "Network connection lost! Pausing execution..."
    update_status "NETWORK LOST: Paused waiting for connection..." "\e[41m\e[97m" # Red background
    
    while [ $retries -lt $max_retries ]; do
        if curl -I --connect-timeout 3 -s "$host" &>/dev/null || curl -I --connect-timeout 3 -s "$fallback" &>/dev/null; then
            print_action "Network connection restored. Resuming..."
            return 0
        fi
        ((retries++))
        sleep 5
    done
    
    error "Network connection lost for over 5 minutes. Aborting installation."
    exit 1
}