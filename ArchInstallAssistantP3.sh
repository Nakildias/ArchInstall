#!/bin/bash
echo "Welcome to Arch Install Assistant (Part 3/3)"
echo "Unmounting Everything"
umount -R /mnt
echo "Installation finsished..."
read -p "PRESS ENTER TO SHUTDOWN"
shutdown now
