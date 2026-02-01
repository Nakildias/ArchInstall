# Arch Linux Installer v3.0

![Version](https://img.shields.io/badge/version-3.0-blue) ![License](https://img.shields.io/badge/license-CC0-green) ![Architecture](https://img.shields.io/badge/arch-x86__64-orange)

A secure, automated, and modular Arch Linux installation system. This script provides a streamlined way to install a fully configured Arch Linux system, supporting both interactive use and configuration-file driven automation.

## Quick Links
- [Specs at a Glance](#specs-at-a-glance)
- [Key Features](#key-features)
- [Supported Profiles](#supported-profiles)
- [Installation](#installation)
- [Usage Modes](#usage-modes)
- [Advanced Features](#advanced-features)

## Specs at a Glance

| Category | Supported Technologies |
| :--- | :--- |
| **Boot Mode** | UEFI (systemd-boot/GRUB), Legacy BIOS (GRUB) |
| **Filesystems** | Ext4, XFS, Btrfs (Subvolumes: `@`, `@home`, `@snapshots`, `@var_log`) |
| **Encryption** | LUKS Full Disk Encryption |
| **Swap** | ZRAM (Default), Swap Partition, Swapfile |
| **Network** | NetworkManager, iwd, ssh, automatic mirror selection |

## Hardware Auto-Detection

The installer automatically identifies your hardware and configures the system accordingly:

*   **Microcode:** Auto-installs `intel-ucode` or `amd-ucode`.
*   **GPU Drivers:** 
    *   **NVIDIA:** Proprietary drivers.
    *   **AMD/Intel:** Open-source Mesa drivers.
    *   **VMware:** SVGA drivers.
    *   **QEMU:** Virtio drivers.
*   **Virtualization Tools:** Automatically installs guest agents for **VMware** (`open-vm-tools`) and **QEMU/KVM** (`qemu-guest-agent`, `spice-vdagent`).

## Key Features

### 🛡️ Security First
*   **Secure Password Handling:** Passwords passed via file descriptors (pipes), scrubbing them from process lists.
*   **Safe Sudoers Management:** Uses temporary drop-in files for installation privileges, cleaned up automatically to prevent race conditions.
*   **Zero-Trace Cleanup:** Securely wipes environment files containing credentials before the final boot.
*   **Targeted Disk Operations:** Disk wiping logic is strictly scoped to the target drive.

### ⚙️ Configuration & Customization
*   **Network Resilience:** Robust connectivity checks with 5-minute timeouts and retries.
*   **KDE Theming Engine:** Integrated `Konsave` support to apply full Plasma layouts, wallpapers, and widgets.
*   **Locale & Input:** Full selection support for 14+ Locales and 12+ Keymaps.
*   **TTY Ricing:** Optional high-resolution KMSCON console setup with custom themes (Nord, Dracula).

### 🛟 Safety & Recovery
*   **Config Backups:** Automatically backs up existing configuration files (e.g., `.zshrc`, `tmux.conf`) before overwriting.
*   **Repair Mode:** Standalone tool (`repair.sh`) to fix bootloaders, fstab, and kernels (Btrfs aware).
*   **Kexec Support:** "Soft reboot" directly into the new kernel without a full hardware cycle.

## Supported Profiles

| Profile | GUI | Audio | Theming | Description |
| :--- | :---: | :---: | :---: | :--- |
| **KDE Plasma** | ✅ | ✅ | ✅ | Full desktop experience with Konsave support. |
| **Hyprland** | ✅ | ✅ | ❌ | Modern tiling compositor. |
| **GNOME** | ✅ | ✅ | ❌ | Standard GNOME environment. |
| **XFCE/MATE** | ✅ | ✅ | ❌ | Lightweight, traditional desktops. |
| **LXQt** | ✅ | ✅ | ❌ | Extremely lightweight Qt environment. |
| **Server** | ❌ | ❌ | ❌ | Headless, SSH only, minimal footprint. |

## Installation

### Prerequisites
1.  **Arch Linux ISO:** Boot from recent official media.
2.  **Internet:** Ethernet or Wi-Fi (`iwctl`).
3.  **Root Access:** Run as root.

### Quick Start

Update, Clone, and Run in one go:

```bash
pacman -Sy git --noconfirm
git clone https://github.com/Nakildias/ArchInstall && cd ArchInstall
./install.sh
```

> [!WARNING]
> **Data Loss Warning:** This software creates partitions and formats disks. It is designed to WIPE the target drive specified. Always verify your target disk selection.

## Usage Modes

### Interactive Mode
Simply run `./install.sh`. You will be guided through disk selection, encryption, and profile choices.

### Configuration Mode (Automated)
Automate installations using `.conf` files found in `config/`.

```bash
./install.sh --config config/my-custom-config.conf
```

**Minimal Config Example:**
```bash
HOSTNAME="arch-server"
TARGET_DISK="/dev/vda"
SELECTED_FS="btrfs"
ENABLE_ROOT_ACCOUNT="true"
ROOT_PASSWORD="securePassword123"
DE_NAME="Server"
```

## Advanced Features

### Repair Script
`repair.sh` is a powerful standalone tool included in the repository.
*   **Auto-Detect:** Btrfs subvolumes & EFI partitions.
*   **Fixes:** Reinstall Bootloader, Regenerate fstab, Reinstall Kernel.

```bash
./repair.sh
```

### Local Mirror
Use a local caching proxy for rapid deployments.
*   **Config:** Set `USE_LOCAL_MIRROR="true"` and `LOCAL_MIRROR_URL="http://ip:port"`.

## Project Structure
*   `install.sh`: Entry point.
*   `lib/`: Core logic (disk, network, chroot).
*   `config/`: Automation profiles.
*   `Customizers/`: DE-specific post-install scripts.
*   `Scripts/`: Standalone utilities.
