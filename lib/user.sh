#!/bin/bash

# --- User & Identity Configuration ---

configure_hostname_user() {
    update_status "Step 2/12: User Configuration"
    print_header "USER & HOSTNAME"
    print_action "Configuring system identity..."

    # MODIFIED: Skip hostname prompt if configured
    if [[ "$USE_CONFIG" == "true" && -n "${HOSTNAME:-}" ]]; then
        print_subitem "Using hostname from config: ${HOSTNAME}"
    else
        while true; do
            prompt "Enter hostname (e.g., arch-pc): " HOSTNAME
            # Strict validation: Min 3 chars, lowercase, alpha-numeric, hyphen, underscore. No "root".
            if [[ ! "$HOSTNAME" =~ ^[a-z0-9_-]{3,}$ ]]; then
                error "Hostname invalid. Must be lowercase only, at least 3 chars (a-z, 0-9, -, _)."
            elif [[ "$HOSTNAME" == "root" ]]; then
                error "Hostname cannot be 'root'."
            else
                break
            fi
        done
    fi

    # --- Root Account Configuration ---
    # Do NOT set defaults here - we need to detect if config has these explicitly set or not
    # ROOT_PASSWORD is already empty if not set.

    # Check config first: only skip interactive if ENABLE_ROOT_ACCOUNT is explicitly "true" or "false"
    if [[ "$USE_CONFIG" == "true" && ( "${ENABLE_ROOT_ACCOUNT:-}" == "true" || "${ENABLE_ROOT_ACCOUNT:-}" == "false" ) ]]; then
        if [[ "$ENABLE_ROOT_ACCOUNT" == "true" && -n "${ROOT_PASSWORD:-}" ]]; then
            print_subitem "Root account enabled and password set via config."
        elif [[ "$ENABLE_ROOT_ACCOUNT" == "false" ]]; then
             print_subitem "Root account disabled via config."
        else
            # Config enabled root but no password? Fallback to ask
             if [[ "$ENABLE_ROOT_ACCOUNT" == "true" ]]; then
                print_subitem "Root account enabled via config, but no password found."
                get_password "root user" "ROOT_PASSWORD"
             fi
        fi
    else
        # Interactive Mode (config not set, or not using config)
        if confirm "Enable Root account? (If no, root will be locked and sudo recommended)"; then
            ENABLE_ROOT_ACCOUNT=true
            get_password "root user" "ROOT_PASSWORD"
        else
            print_subitem "Root account will be disabled (locked)."
            ENABLE_ROOT_ACCOUNT=false
        fi
    fi

    # --- User Accounts Configuration ---
    # Only reset arrays if NOT using config or if array is empty
    # Fix: Check if USER_NAMES is set (-v) before checking length to avoid unbound variable error
    if [[ "$USE_CONFIG" == "true" && -v USER_NAMES && ${#USER_NAMES[@]} -gt 0 ]]; then
        print_action "User accounts pre-loaded from config."
        
        # Validate other arrays exist, if not, fill with defaults or error?
        # For simplicity, we assume if USER_NAMES is set in a dev config, the others are too.
        # But we should be safe.
        if [[ ! -v USER_PASSWORDS ]]; then USER_PASSWORDS=(); fi
        if [[ ! -v USER_SUDO ]]; then USER_SUDO=(); fi
        
        # Print summary of loaded users
        for i in "${!USER_NAMES[@]}"; do
             print_subitem "Loaded User: ${USER_NAMES[$i]} (Sudo: ${USER_SUDO[$i]:-false})"
        done
        
        # SKIP interactive loop
    else
        USER_NAMES=()
        USER_PASSWORDS=()
        USER_SUDO=()

        print_action "Configuring user accounts..."
        while true; do
            # If no users yet (or cleared), we must force adding at least one
            if [ ${#USER_NAMES[@]} -eq 0 ]; then
                 print_subitem "You must create at least one user account."
            elif ! confirm "Add another user?"; then
                 break
            fi

            while true; do
                prompt "Enter username: " CURRENT_USER
                # Strict validation: Min 3 chars, lowercase, alpha-numeric, hyphen, underscore. No "root".
                if [[ ! "$CURRENT_USER" =~ ^[a-z0-9_-]{3,}$ ]]; then
                     error "Username invalid. Must be at least 3 chars, lowercase, numbers, '-', or '_'."
                     continue
                fi
                
                if [[ "$CURRENT_USER" == "root" ]]; then
                    error "Username cannot be 'root' (reserved)."
                    continue
                fi

                # Check for duplicates using associative array logic or looping
                # Since we already have the regex check, we just proceed.
                    # Check for duplicates
                    local is_dup=false
                    for existing in "${USER_NAMES[@]}"; do
                        if [[ "$existing" == "$CURRENT_USER" ]]; then
                            is_dup=true
                            break
                        fi
                    done

                    if [[ "$is_dup" == "true" ]]; then
                        error "Username '$CURRENT_USER' already added."
                        continue
                    fi

                    break
            done

            get_password "user '${CURRENT_USER}'" "CURRENT_PASS"

            local use_sudo="false"
            if confirm "Grant sudo rights (wheel group) to '${CURRENT_USER}'?"; then
                use_sudo="true"
            fi

            # Add to arrays
            USER_NAMES+=("$CURRENT_USER")
            USER_PASSWORDS+=("$CURRENT_PASS")
            USER_SUDO+=("$use_sudo")

            print_subitem "User '${CURRENT_USER}' added to configuration."
        done
    fi
}
