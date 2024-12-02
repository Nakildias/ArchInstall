#!/bin/bash
  clear
  echo "Welcome to Arch Install Assistant (Part 1/2)"
  echo "Checking EFI"
if [ ! -e "/sys/firmware/efi/fw_platform_size" ]; then
  echo "EFI firmware not available exiting..."
  exit 1
fi
  echo "EFI firmware available"
  read -p "Press ENTER to continue"
  clear
  fdisk -l
  echo "Input the disk you want to use to install Arch Linux"
  echo "Example if you get [Disk /dev/vda: 64 GiB], then write vda"
  echo "Example if you get [Disk /dev/sda: 128 GiB], then write sda"
  read -p "Disk = " disk
  echo "You will now be taken to the disk partitioner."
  echo "You will need to make 3 partitions"
  echo "Boot Parition of 1GB,"
  echo "Swap Partition of 4GB or more,"
  echo "Root Partition with what is remaining."
  read -p "Press ENTER to continue"
  sudo cfdisk /dev/$disk
  clear
  fdisk -l
  echo "Please enter the correct partition name for each partitions"
  echo "Example"
  echo "Boot Partition = vda1"
  echo "Swap Partition = vda2"
  echo "Root Partition = vda3"
  read -p "Boot Partition : " Partition_Boot
  read -p "Swap Partition : " Partition_Swap
  read -p "Root Partition : " Partition_Root
  clear
  echo "$Partition_Boot, $Partition_Swap & $Partition_Root will be formated to their required filesystem."
  read -p "Press ENTER to continue"
  mkfs.fat -F 32 /dev/$Partition_Boot
  mkswap /dev/$Partition_Swap
  mkfs.ext4 /dev/$Partition_Root
  echo "Partitioning Done"
  echo "Mounting partitions..."
  mount /dev/$Partition_Root /mnt
  mount --mkdir /dev/$Partition_Boot /mnt/boot
  swapon /dev/$Partition_Swap
  echo "Mounting Completed"
  echo "Pacstraping..."
  read -p "Enable Parallel Downloads for pacstrap? y/n = " Parallel
  if [ "${Parallel,,}" = "y" ]; then
  read -p "How many download threads? 1-10 (default = 5) = " Parallel_Value
  Parallel_Value=${Parallel_Value:-5}
  sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  fi
  
  echo "Choose your kernel ex: linux, linux-zen"
  read -p "Kernel (default = linux) = " kernel
  kernel=${kernel:-linux}
  
  
  echo "NVIDIA?"
  read -p "[y/n]) = " nvidia
  if [ "${nvidia,,}" = "y" ]; then
  video_driver=${video_driver:-nvidia}
  fi
  
  if [ "${nvidia,,}" = "n" ]; then 
  video_driver=${video_driver:-}
  fi
  
  echo "Choose your Desktop Environment"
  echo "0) Server [Tested]"
  echo "1) KDE Plasma [Tested]"
  echo "2) Gnome [Tested]"
  echo "3) LXDE [Unknown]"
  echo "4) Mate [Unknown]"
  echo "5) XFCE [Unknown]"
  read -p "Desktop Environment [0-5] = " de
  de=${de:-0}
  #SERVER
  if [ "${de,,}" = "0" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh 
  fi
  #KDE
  if [ "${de,,}" = "1" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh plasma-meta sddm konsole
  fi
  #GNOME
  if [ "${de,,}" = "2" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh gnome gdm gnome-terminal
  fi
  #LXDE
  if [ "${de,,}" = "3" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh lxde gdm lxterminal
  fi
  #MATE
  if [ "${de,,}" = "4" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh mate gdm mate-terminal
  fi
  #XFCE
  if [ "${de,,}" = "5" ]; then
  pacstrap -K /mnt base $kernel $video_driver mesa linux-firmware base-devel nano efibootmgr networkmanager grub openssh xfce4 lightdm xfce4-terminal
  fi
  
  echo "Generating fstab"
  genfstab /mnt >> /mnt/etc/fstab
  echo "Download Part 2 of Script.."
  mv ./ArchInstallAssistantP2.sh /mnt/ArchInstallAssistantP2.sh
  echo "After chrooting you will need to bash into part 2"
  echo "Location = /ArchInstallAssistantPart2.sh"
  read -p "Press ENTER to continue"
  echo "Chrooting into /mnt"
  arch-chroot /mnt
# Written by Nakildias
