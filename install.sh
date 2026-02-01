#!/bin/bash

# ==============================================================================
# Arch Linux Installation Script - Modular Edition
# Version: 3.1 (UI Overhaul)
# ==============================================================================

# Get the directory of the script
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
LIB_DIR="${SCRIPT_DIR}/lib"

# --- Source Modules ---
source "${LIB_DIR}/config.sh"
source "${LIB_DIR}/utils.sh"
source "${LIB_DIR}/menus.sh"
source "${LIB_DIR}/system.sh"
source "${LIB_DIR}/disk.sh"
source "${LIB_DIR}/user.sh"
source "${LIB_DIR}/chroot.sh"
source "${LIB_DIR}/phases.sh"

# --- Main Installation Logic ---

main() {
    # 0. Argument Parsing
    export VERBOSE_MODE="false"
    for arg in "$@"; do
        case $arg in
            -v|--verbose)
                VERBOSE_MODE="true"
                ;;
        esac
    done

    # 1. Environment & Connectivity
    setup_environment "$@"
    check_dependencies
    check_boot_mode
    check_internet

    # 2. Time & Auto-Timezone Sync
    sync_time_and_timezone

    # 3. Load Configuration Profile
    load_config_profile

    # 4. Interactive Prompts (Will skip values already set in config)
    select_disk
    configure_partitioning
    configure_hostname_user
    select_timezone
    select_locale
    select_kernel
    select_bootloader
    select_gpu_driver
    select_desktop_environment
    select_optional_packages
    select_tty_rice_config
    select_kde_theme
    select_filesystem
    select_swap_choice
    ask_encryption
    ask_kexec_preference
    select_mirror_preference

    # 5. Final Summary and Installation
    show_summary
    configure_mirrors
    partition_and_format
    mount_filesystems
    install_base_system
    configure_installed_system
    install_bootloader

    # 6. Finish
    final_steps
}

# --- Run the main function ---
main "$@"

# Exit menu handles final interaction
exit_menu
exit 0
