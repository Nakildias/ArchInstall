# Arch Installation Script by Nakildias
> Made for x86_64 UEFI & Legacy BIOS
##  Step 1 - Boot Arch from USB
##  Step 2 - Install Git and Clone the repo
> pacman -Sy git
##
> git clone https://github.com/Nakildias/ArchInstall.git
## If you are having issues with corrupted packages or invalid signatures update the archlinux keyring.
> pacman -Sy archlinux-keyring
##  Step 3 - CD into ArchInstall directory
> cd ArchInstall
##  Step 4 - Bash into install.sh
>bash install.sh
##  Step 4 - Follow steps in terminal
### You will see green text that says installation successful when installation is done.
### Simply reboot now shutdown your system
### The script should tell you the commands to use to shutdown or restart in green text.
##  Step 5 - Post Install Script (Optional & Unfinished)
> git clone https://github.com/Nakildias/ArchInstall.git
##
> cd ArchInstall
##
> bash post-install.sh
