#!/bin/bash
# Customizer for Hyprland (AUR Packages & Tweaks)

source /etc/chroot_env.sh

if [[ "$BUILD_USER" ]]; then
    info "Installing Hyprland specific AUR packages for user: $BUILD_USER"
    
    # swaylock-effects is an AUR package usually
    # We use the build user to install it
    exec_silent run_with_retry sudo -u "$BUILD_USER" yay -S --noconfirm swaylock-effects
    
    check_status_chroot "Installing swaylock-effects via Yay"
fi
