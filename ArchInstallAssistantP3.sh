#!/bin/bash
echo "Welcome to Arch Install Assistant (Part 3/3)"
echo "Cleaning Scripts"
rm -rf /mnt/Grub-Themes
rm /mnt/ArchInstallAssistantP2.sh

echo "Unmounting Everything"
umount -R /mnt
read -p "Press [Enter] to complete the installation."
shutdown now
