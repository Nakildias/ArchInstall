#!/bin/bash
# Customizers/KDE-Plasma.sh
# Handles KDE Theme Application, Konsave, and Wallpaper

# Source shared environment
if [ -f /etc/chroot_env.sh ]; then
    source /etc/chroot_env.sh
fi

info "Starting KDE Plasma Customization..."

# Debug Logging Redirect
LOG_USER="${BUILD_USER:-root}"
mkdir -p "/home/$LOG_USER/Desktop"
LOG_FILE="/home/$LOG_USER/Desktop/kde_customizer_debug.log"
exec > >(tee -a "$LOG_FILE") 2>&1

if [[ -n "${SELECTED_THEME_FILENAME}" ]] && [[ "${INSTALL_YAY}" == "true" ]]; then
    info "Installing KDE Theme: ${SELECTED_THEME_FILENAME}"

    THEME_PATH="/opt/archinstall_themes/${SELECTED_THEME_FILENAME}"
    if [ ! -f "$THEME_PATH" ]; then
        error "Theme file not found at $THEME_PATH"
        exit 1
    fi

    # 1. Install Konsave (Python based KDE config manager)
    if ! command -v konsave &> /dev/null; then
        if [[ -n "$BUILD_USER" ]]; then
            info "Installing Konsave from AUR..."
            exec_silent run_with_retry sudo -u "$BUILD_USER" bash -c "source /etc/chroot_env.sh && cd /home/$BUILD_USER && yay -S --noconfirm --needed konsave"
            check_status_chroot "Installing konsave"
        else
            warn "No build user found. Cannot install Konsave."
            exit 1
        fi
    fi

    # 2. Update Theme Dependencies install
    if [[ -n "$THEME_YAY_DEPS" ]]; then
        info "Installing Theme Dependencies: $THEME_YAY_DEPS"
        exec_silent run_with_retry sudo -u "$BUILD_USER" bash -c "cd /home/$BUILD_USER && yay -S --noconfirm --needed $THEME_YAY_DEPS"
    fi

    # 3. Apply Theme for Target Users
    apply_users=()
    if [[ "$TARGET_THEME_USERS" == "all" ]]; then
       apply_users=("${USER_NAMES[@]}")
    else
       # If it's a single user or space separated
       read -r -a apply_users <<< "$TARGET_THEME_USERS"
    fi

    for user in "${apply_users[@]}"; do
        info "Applying KDE Theme for user: $user"
        USER_HOME="/home/$user"
        
        # 1. Create Directories & Fix Permissions (Matches original script logic)
        mkdir -p "$USER_HOME/.local/share/konsole" "$USER_HOME/.config" "$USER_HOME/.cache"
        chown -R "$user:$user" "$USER_HOME/.local" "$USER_HOME/.config" "$USER_HOME/.cache"

        # A. Import the .knsv file
        PROFILE_NAME=$(basename "$SELECTED_THEME_FILENAME" .knsv)
        
        info "Importing Konsave profile '$PROFILE_NAME' for user $user..."
        sudo -u "$user" konsave -i "$THEME_PATH" --force
        
        # Apply IMMEDIATELY (Offline Config Update)
        info "Applying Konsave profile '$PROFILE_NAME'..."
        sudo -u "$user" konsave -a "$PROFILE_NAME"
        
        PROFILE_ID="$PROFILE_NAME"
        
        # B. Wallpaper Logic
        if [[ -n "$THEME_WALLPAPER_FILENAME" ]]; then
            WP_SRC="/opt/archinstall_themes/$THEME_WALLPAPER_FILENAME"
            WP_DEST="$USER_HOME/.local/share/wallpapers/$THEME_WALLPAPER_FILENAME"
            mkdir -p "$USER_HOME/.local/share/wallpapers"
            cp "$WP_SRC" "$WP_DEST"
            chown -R "$user:$user" "$USER_HOME/.local/share/wallpapers"
            
            # Setup Plasma Script to set wallpaper
            mkdir -p "$USER_HOME/.config/autostart"
            
cat <<EOF_WP_SCRIPT > "$USER_HOME/.config/apply_theme_fix.sh"
#!/bin/bash
exec > "\$HOME/theme_fix.log" 2>&1
set -x

echo "Waiting for Plasma to start..."
# Wait max 30 seconds for plasmashell to appear
for i in {1..30}; do
    if pgrep -x "plasmashell" > /dev/null; then
        echo "Plasma detected after \$i seconds."
        break
    fi
    sleep 1
done
# Give it a few more seconds to initialize DBus
sleep 5

# Find qdbus
QDBUS="qdbus"
if ! command -v qdbus &>/dev/null; then
    if command -v qdbus6 &>/dev/null; then
        QDBUS="qdbus6"
    elif command -v qdbus-qt6 &>/dev/null; then
        QDBUS="qdbus-qt6"
    fi
fi
echo "Using QDBUS: \$QDBUS"

# Apply Konsave Profile if needed
if [[ -n "$PROFILE_ID" ]]; then
    echo "Applying Konsave Profile: $PROFILE_ID"
    konsave -a "$PROFILE_ID"
    # Konsave needs a reload usually? It usually reloads kwin/plasma itself or via args.
    # We can force a reload if needed.
fi

# Apply Wallpaper via DBus
if [[ -n "\$QDBUS" ]]; then
    echo "Setting wallpaper..."
    \$QDBUS org.kde.plasmashell /PlasmaShell org.kde.PlasmaShell.evaluateScript "
    var allDesktops = desktops();
    for (i=0;i<allDesktops.length;i++) {
        d = allDesktops[i];
        d.wallpaperPlugin = \"org.kde.image\";
        d.currentConfigGroup = Array(\"Wallpaper\", \"org.kde.image\", \"General\");
        d.writeConfig(\"Image\", \"file://$WP_DEST\");
    }
"
else
    echo "ERROR: qdbus not found. Wallpaper cannot be set."
fi

# Self Destruct
rm "\$0"
EOF_WP_SCRIPT

            chmod +x "$USER_HOME/.config/apply_theme_fix.sh"
            chown "$user:$user" "$USER_HOME/.config/apply_theme_fix.sh"
            
            # Create Desktop Entry for Autostart
            cat <<EOF_AUTO > "$USER_HOME/.config/autostart/theme_fix.desktop"
[Desktop Entry]
Type=Application
Name=Theme Fixer
Exec=$USER_HOME/.config/apply_theme_fix.sh
X-KDE-autostart-condition=ksmserver
EOF_AUTO
            chown "$user:$user" "$USER_HOME/.config/autostart/theme_fix.desktop"
        fi
    done
    
    success "KDE Theme setup tasks complete."
fi
