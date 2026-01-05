# Arch Linux Installation Script v3.0 🚀

A fast, automated, and feature-rich Arch Linux installer for x86_64 systems. Seamlessly supports both UEFI and Legacy BIOS boot modes.

# Major update coming soon need to test it throughly then it will be available here!

This script transforms a fresh Arch ISO into a fully configured, performance-optimized workstation or server in minutes. It handles the manual heavy lifting—partitioning, mounting, and base installation—along side complex configurations like driver detection, auto-login, and AUR setup.

## ✨ Key Features ✨

*   **Hybrid Boot Support**: Automatically detects UEFI or Legacy BIOS. Uses GPT partitioning for both.
*   **Smart Bootloader Selection**: Choose between GRUB or systemd-boot (UEFI only).
*   **Full Disk Encryption**: Secure your system with LUKS encryption support.
*   **Linear Installation**: A guided, linear workflow ensures you never miss a critical configuration step.
*   **Instant Boot (Kexec)**: Experimental feature to boot directly into your new OS without a hardware reboot.
*   **Desktop Environment Profiles**:
    *   KDE Plasma 6, GNOME, XFCE, MATE, LXQt.
    *   **Server**: TTY/SSH only configuration. (Or DIY without any bloat.)
    *   **Nakildias Custom**: Pre-tuned KDE Gaming profile with OBS, Virtualization and streaming tools.
*   **Performance Optimized**:
    *   Multi-core makepkg configuration.
    *   Parallel Pacman downloads (5x speed).
    *   **Automatic Timezone**: Detects and applies your correct timezone automatically.
    *   Automatic fastest mirror selection via Reflector.
*   **Gaming & Dev Ready**: Optional Steam/Discord packs and **Integrated Yay Installer** (AUR helper) for effortless package management.

## ⚠️ Disclaimer ⚠️

> **Data Loss Warning**: This script WILL WIPE the target disk you select. Backup your data first.
>
> **Use at your own risk**: While tested, always verify your disk selection. This is intended for clean installations only.

## 📋 Prerequisites 📋

*   **x86_64 System**: A 64-bit compatible computer.
*   **Arch Linux ISO**: Boot from a recent official Arch Linux USB.
*   **Internet**: Ensure you have an active connection (via Ethernet or `iwctl` for Wi-Fi).

## ⚙️ Installation Guide ⚙️

Follow these steps exactly to deploy your system.

### 1. Verify Internet Connection

Before starting, ensure the Arch Live environment can reach the outside world:

```bash
ping -c 3 archlinux.org
```

### 2. Download and Run the Script

Copy and paste the following commands into your terminal:

```bash
# Update package database and install Git
pacman -Sy git --noconfirm

# Clone the repository
git clone https://github.com/Nakildias/ArchInstall

# Navigate into the installer directory
cd ArchInstall

# Execute the installation script
bash install.sh
```

### 3. Configure Your Install

Once the script starts, follow the on-screen instructions. You will be prompted to:

*   Select your target drive (e.g., `/dev/sda` or `/dev/nvme0n1`).
*   Set your hostname and user credentials.
*   Choose your preferred Desktop Environment or Server profile.
*   Toggle optional features like Gaming Essentials or Zsh.

## Post-Installation

After the script finishes, you can choose to use the Kexec feature to jump straight into your new OS, or perform a traditional reboot. Installation logs are preserved at `/var/log/installer` for your review.
