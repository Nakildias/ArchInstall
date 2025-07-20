# Arch Linux Installation Script by Nakildias 🚀

**Automate your Arch Linux installation on x86_64 systems, supporting both UEFI and Legacy BIOS.**

This script is designed to simplify the Arch Linux installation process. Please follow the steps carefully.

## ⚠️ Disclaimer
* **Use at your own risk.** While this script aims to automate the installation, you are responsible for understanding the commands being executed.
* **Backup your data.** Ensure any important data on the target machine is backed up before proceeding, as this script will partition and format your drive.
* This script is intended for a clean installation of Arch Linux.

## 📋 Prerequisites
* An x86_64 compatible machine.
* A bootable Arch Linux USB drive. You can create one by following the official Arch Linux installation guide.
* An active internet connection on the machine where you'll be running the script.

## ⚙️ Installation Steps

### Step 1: Boot from Arch Linux USB
1.  Boot your computer from the Arch Linux USB drive you prepared.
2.  Ensure you are connected to the internet. You can use `iwctl` for Wi-Fi or ensure an Ethernet cable is connected.

### Step 2: Prepare for Script Execution
1.  **Install Git:**
    The script requires Git to be cloned. Open a terminal and type:
    ```bash
    pacman -Sy git --noconfirm
    ```
2.  **Troubleshooting Git Installation (If Needed):**
    If you encounter issues installing Git, especially keyring errors, run the following commands and then try installing Git again:
    ```bash
    pacman-key --init
    pacman-key --populate archlinux
    pacman -Sy archlinux-keyring --noconfirm
    pacman -Sy git --noconfirm # Retry Git installation
    ```
3.  **Clone the Repository:**
    Once Git is installed, clone this repository.
    *Note: Pay attention to capitalization to avoid issues.*
    ```bash
    git clone https://github.com/Nakildias/ArchInstall
    ```

### Step 3: Run the Installation Script
1.  **Navigate to the Script Directory:**
    ```bash
    cd ArchInstall
    ```
2.  **Execute the Installation Script:**
    ```bash
    bash install.sh
    ```
3.  **Follow On-Screen Instructions:**
    The script will guide you through the installation process. Pay close attention to the prompts and provide the required information.
4.  **Installation Complete:**
    Upon successful completion, you will see a message in **green text** indicating that the installation was successful. The script should also provide commands to either `reboot` or `shutdown` your system.
    ```bash
    # Execute one of those for a graceful shutdown:
    # reboot
    # shutdown now
    ```
    Remove the Arch Linux USB drive after shutting down or during the reboot process.

## 🔧 Step 4: Post-Installation Script (Makes your shell better looking and nicer to user and also installs yay for you.)

1.  **Clone the Repository (if not already cloned or if you removed it):**
    After rebooting into your new Arch Linux system and logging in, open a terminal and run:
    ```bash
    git clone [https://github.com/Nakildias/ArchInstall.git](https://github.com/Nakildias/ArchInstall.git)
    ```
2.  **Navigate to the Script Directory:**
    ```bash
    cd ArchInstall
    ```
3.  **Execute the Post-Installation Script:**
    ```bash
    bash post-install.sh
    ```
    Follow any instructions provided by the post-installation script.
