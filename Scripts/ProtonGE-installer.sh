#!/bin/bash

# ==============================================================================
#
#          Proton-GE Downloader and Installer Script
#
#  Author: Nakildias
#  Description: This script automatically downloads the latest Proton-GE release
#               from GitHub, checks if it's already present, and installs it
#               into the Steam compatibility tools directory.
#
# ==============================================================================

# --- Color Definitions ---
# Define ANSI color codes for styled output
readonly COLOR_GREEN='\033[0;32m'
readonly COLOR_RED='\033[0;31m'
readonly COLOR_YELLOW='\033[1;33m'
readonly COLOR_BLUE='\033[0;34m'
readonly COLOR_NC='\033[0m' # No Color

# --- Function for printing styled messages ---
# A helper function to make printing colored text easier.
print_message() {
    local color="$1"
    local message="$2"
    echo -e "${color}${message}${COLOR_NC}"
}

# --- Sudo Check ---
# Exit if the script is run as root (sudo). Steam files should be managed by the user.
if [ "$EUID" -eq 0 ]; then
    print_message "$COLOR_RED" "ERROR: This script should not be run with sudo. Please run it as a normal user."
    exit 1
fi

# --- Configuration ---
# Define the directories for storing archives and for the Steam installation.
# The '~' will be expanded to the user's home directory.
readonly SCRIPT_DIR="$HOME/Scripts/ProtonGE"
readonly STEAM_DIR="$HOME/.steam/root/compatibilitytools.d" # Standard path for most systems
# Fallback for older paths if the primary one doesn't exist
readonly STEAM_DIR_LEGACY="$HOME/.steam/steam/compatibilitytools.d"

# --- Directory Setup ---
# Ensure the script storage and Steam compatibility tools directories exist.
# The 'mkdir -p' command creates parent directories as needed and doesn't
# error if the directory already exists.
print_message "$COLOR_BLUE" "==> Ensuring required directories exist..."
mkdir -p "$SCRIPT_DIR"

# Determine the correct Steam directory and create it
TARGET_STEAM_DIR=""
if [ -d "$HOME/.steam/root" ]; then
    TARGET_STEAM_DIR="$STEAM_DIR"
else
    TARGET_STEAM_DIR="$STEAM_DIR_LEGACY"
fi
mkdir -p "$TARGET_STEAM_DIR"
print_message "$COLOR_GREEN" "    -> Storage directory: $SCRIPT_DIR"
print_message "$COLOR_GREEN" "    -> Steam directory:   $TARGET_STEAM_DIR"


# --- Fetch Latest Release Information ---
# Use the GitHub API to get details about the latest Proton-GE release.
# 'curl -s' fetches the data silently.
print_message "$COLOR_BLUE" "\n==> Fetching latest Proton-GE release information from GitHub..."
API_URL="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases/latest"
API_RESPONSE=$(curl -s "$API_URL")

# Check if the API call was successful
if [ -z "$API_RESPONSE" ]; then
    print_message "$COLOR_RED" "ERROR: Failed to fetch data from GitHub API. Check your internet connection."
    exit 1
fi

# --- Parse API Response ---
# Extract the tag name (version) and the download URL for the .tar.gz file.
# We use 'grep' to find the correct lines and 'sed' to extract the values.
LATEST_TAG=$(echo "$API_RESPONSE" | grep '"tag_name":' | sed -E 's/.*"([^"]+)".*/\1/')
DOWNLOAD_URL=$(echo "$API_RESPONSE" | grep '"browser_download_url":' | grep '\.tar\.gz"' | sed -E 's/.*"([^"]+)".*/\1/')

if [ -z "$LATEST_TAG" ] || [ -z "$DOWNLOAD_URL" ]; then
    print_message "$COLOR_RED" "ERROR: Could not parse API response. The GitHub API format may have changed."
    exit 1
fi

print_message "$COLOR_GREEN" "    -> Latest version found: $LATEST_TAG"

# --- Check if Already Downloaded ---
# Get the filename from the URL and check if it exists in our script directory.
ARCHIVE_NAME=$(basename "$DOWNLOAD_URL")
ARCHIVE_PATH="$SCRIPT_DIR/$ARCHIVE_NAME"

if [ -f "$ARCHIVE_PATH" ]; then
    print_message "$COLOR_YELLOW" "\n==> Latest version ($LATEST_TAG) is already downloaded."
    print_message "$COLOR_YELLOW" "    -> Location: $ARCHIVE_PATH"
    # Optional: Ask user if they want to re-install
    read -p "Do you want to extract it again? (y/N): " choice
    if [[ ! "$choice" =~ ^[Yy]$ ]]; then
        print_message "$COLOR_GREEN" "Exiting."
        exit 0
    fi
else
    # --- Download the Archive ---
    print_message "$COLOR_BLUE" "\n==> Downloading $LATEST_TAG..."
    # Use 'wget' to download the file, showing a progress bar.
    wget -q --show-progress -O "$ARCHIVE_PATH" "$DOWNLOAD_URL"
    if [ $? -ne 0 ]; then
        print_message "$COLOR_RED" "ERROR: Download failed. Please check the URL or your connection."
        # Clean up partially downloaded file
        rm -f "$ARCHIVE_PATH"
        exit 1
    fi
    print_message "$COLOR_GREEN" "    -> Download complete!"
fi

# --- Install Proton-GE ---
# Extract the downloaded archive into the Steam compatibility tools directory.
# The '-C' flag tells 'tar' to change to the specified directory before extracting.
print_message "$COLOR_BLUE" "\n==> Installing $LATEST_TAG..."
tar -xvf "$ARCHIVE_PATH" -C "$TARGET_STEAM_DIR"

if [ $? -ne 0 ]; then
    print_message "$COLOR_RED" "ERROR: Extraction failed. The archive may be corrupt."
    exit 1
fi

# --- Final Message ---
print_message "$COLOR_GREEN" "\n✅ Success! Proton-GE $LATEST_TAG has been installed."
print_message "$COLOR_YELLOW" "You may need to restart Steam for the new version to appear in the compatibility list."
echo ""

exit 0
