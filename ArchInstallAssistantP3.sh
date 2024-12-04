#!/bin/bash
echo "Unmounting Everything"
umount -R /mnt
echo "Installation finsished..."
read -p "PRESS ENTER TO SHUTDOWN"
shutdown now
