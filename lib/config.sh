#!/bin/bash

# --- Configuration ---
SCRIPT_VERSION="3.0" # Updated version
DEFAULT_KERNEL="linux"
DEFAULT_PARALLEL_DL=5
MIN_BOOT_SIZE_MB=512 # Minimum recommended boot size in MB
DEFAULT_REGION="America" # Default timezone region (Adjust as needed)
DEFAULT_CITY="Toronto"   # Default timezone city (Adjust as needed)
INSTALL_SUCCESS="false"
INSTALL_NVIDIA="false"
ENABLE_TTY_RICE=""
SELECTED_THEME_FILE=""
TARGET_THEME_USERS=""
SELECTED_THEME_NAME=""
TTY_RES=""

# Color definitions
C_OFF='\033[0m'
C_RED='\033[0;31m'
C_GREEN='\033[0;32m'
C_YELLOW='\033[0;33m'
C_BLUE='\033[0;94m'
C_PURPLE='\033[0;35m'
C_CYAN='\033[0;36m'
C_WHITE='\033[0;37m'
C_BOLD='\033[1m'
