#!/bin/bash
  clear
  echo "Welcome to Arch Install Assistant (Part 1/3)"
  echo "Checking EFI"
  if [ ! -e "/sys/firmware/efi/fw_platform_size" ]; then
  echo "EFI firmware not available"
  echo "Fix this by enabling UEFI in your bios"
  while true; do
  sleep 60
  done
  fi
  echo "EFI firmware available"
  echo "NO FAILSAFE EXISTS DURING THE PARTITIONS SETUP"
  echo "IF YOU MESS SOMETHING UP HERE RESTART THE SCRIPT"
  read -p "Press ENTER to continue"
  clear
  # Retrieve a list of valid disks
  valid_disks=($(fdisk -l | awk '/^Disk \/dev\// {gsub(":", "", $2); print $2}' | cut -d'/' -f3))
  # Check if any disks are available
  if [ ${#valid_disks[@]} -eq 0 ]; then
  echo "No valid disks found. Exiting."
  exit 1
  fi
  # Display available disks
  #echo "Available disks: ${valid_disks[@]}"
  # Loop to get a valid disk input
  #while true; do
  #read -p "Disk = " disk
  #if [[ " ${valid_disks[@]} " =~ " ${disk} " ]]; then
  #echo "You selected a valid disk: $disk"
  #break
  #else
  #echo "Invalid disk. Please try choose a valid disk."
  #clear
  #echo "Available disks: ${valid_disks[@]}"
  #fi
  #done
  #echo "You will need to make 3 partitions"
  #sleep 1
  #echo "1#Boot Parition of 1G or >"
  #sleep 1
  #echo "2#Swap Partition of 4G or >"
  #sleep 1
  #echo "3#Root Partition with what is remaining."
  #sleep 1
  #echo "When done do [write] first and then [quit] in cfdisk"
  #echo "If you mess up here please restart this script"
  #echo "|--------------------------------------------------------|"
  #echo "|!!WARNING!! PARTITION THOSE IN CORRECT ORDER !!WARNING!!|"
  #echo "|--------------------------------------------------------|"
  #read -p "Press ENTER to get in cfdisk"
  #sudo cfdisk /dev/$disk
################################################ Testing
# Retrieve a list of valid disks
valid_disks=($(fdisk -l | awk '/^Disk \/dev\// {gsub(":", "", $2); print $2}' | cut -d'/' -f3))

# Check if any disks are available
if [ ${#valid_disks[@]} -eq 0 ]; then
  echo "No valid disks found. Exiting."
  exit 1
fi

# Display available disks
echo "Available disks: ${valid_disks[@]}"

# Loop to get a valid disk input
while true; do
  read -p "Disk = " disk
  if [[ " ${valid_disks[@]} " =~ " ${disk} " ]]; then
    echo "You selected a valid disk: $disk"
    break
  else
    echo "Invalid disk. Please try again."
  fi
done

# Confirm the user wants to erase the disk
read -p "Warning: This will erase all data on /dev/$disk. Are you sure? (yes/no): " confirmation
if [[ "$confirmation" != "yes" ]]; then
  echo "Operation canceled."
  exit 1
fi

# Check for existing partitions and delete them
echo "Checking for existing partitions on /dev/$disk..."
partitions=($(lsblk -np | grep "/dev/$disk" | awk '{print $1}'))
if [ ${#partitions[@]} -gt 0 ]; then
  echo "Found partitions: ${partitions[@]}"
  for part in "${partitions[@]}"; do
    part_number=$(echo $part | grep -o '[0-9]*$')
    echo "Deleting partition $part (Partition number: $part_number)..."
    parted -s /dev/$disk rm $part_number
  done
  echo "All existing partitions deleted."
else
  echo "No existing partitions found on /dev/$disk."
fi

# Ask for the swap size
while true; do
  read -p "Enter Swap Size (e.g., 2G, 512M): " SwapSize
  if [[ $SwapSize =~ ^[0-9]+[MG]$ ]]; then
    echo "Swap size set to: $SwapSize"
    break
  else
    echo "Invalid swap size. Please enter a size in the format '2G' or '512M'."
  fi
done

# Partition the disk
echo "Partitioning /dev/$disk..."
(
echo g # Create a new GPT partition table
echo n # New partition
echo 1 # Partition number 1
echo   # Default - start at beginning of disk
echo +1G # End at 1GB

echo n # New partition
echo 2 # Partition number 2
echo   # Default - start immediately after previous partition
echo +$SwapSize # End at SwapSize

echo n # New partition
echo 3 # Partition number 3
echo   # Default - start immediately after previous partition
echo   # Default - use the rest of the disk

echo w # Write the changes
) | fdisk /dev/$disk

# Display the partition table
echo "Partitioning complete. Updated disk layout:"
fdisk -l /dev/$disk
################################################################ TESTING
  clear
  Partition_Boot=${Partition_Boot:-$disk\1}
  Partition_Swap=${Partition_Swap:-$disk\2}
  Partition_Root=${Partition_Root:-$disk\3}
  fdisk -l
  echo ""
  echo "$Partition_Boot (BOOT) | $Partition_Swap (SWAP) | $Partition_Root (ROOT)"
  echo ""
  echo "Partitions above will be formated to their required filesystem."
  read -p "Press ENTER if everything seems OK"
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
  echo "FAILSAFE EXISTS DURING THE REST OF PART 1"
  echo "IF YOU MESS SOMETHING UP IT WILL ASK INPUT AGAIN"
  #
  #
  #BEGIN ENABLE PARALLEL DOWNLOADS OPTION
  while true; do
  read -p "Enable Parallel Downloads for pacstrap? y/n = " Parallel
  case "${Parallel,,}" in
  y)
  echo "Parallel Downloads enabled."
  break
  ;;
  n)
  echo "Parallel Downloads not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
  #END ENABLE PARALLEL DOWNLOADS OPTION
  #BEGIN CHOOSING PARALLEL THREADS COUNT
  if [ "${Parallel,,}" = "y" ]; then
  while true; do
  read -p "How many download threads? 1-10 (default = 5) = " Parallel_Value
  Parallel_Value=${Parallel_Value:-5}
  # Check if input is a valid number between 1 and 10
  if [[ "$Parallel_Value" =~ ^[0-9]+$ ]] && ((Parallel_Value >= 1 && Parallel_Value <= 10)); then
  break
  else
  echo "Error: Please enter a number between 1 and 10."
  fi
  done
  echo "You chose $Parallel_Value download threads."
  sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  fi
  #END CHOOSING PARALLEL THREADS COUNT
  #BEGIN CHOOSING KERNEL
  while true; do
  echo "Choose your kernel (valid options: linux, linux-lts, linux-zen)"
  read -p "Kernel (default = linux): " kernel
  kernel=${kernel:-linux} # Default to "linux" if input is empty
  case $kernel in
  linux|linux-lts|linux-zen)
  echo "Selected kernel: $kernel"
  break
  ;;
  *)
  echo "Invalid choice: '$kernel'. Please try again."
  ;;
  esac
  done
  #END CHOOSING KERNEL
  #BEGIN ENABLE NVIDIA OPTION (WIP)
  #echo "NVIDIA?"
  #read -p "[y/n]) = " nvidia
  #if [ "${nvidia,,}" = "y" ]; then
  #video_driver=${video_driver:-nvidia}
  #fi
  #if [ "${nvidia,,}" = "n" ]; then 
  #video_driver=${video_driver:-}
  #fi
  #END ENABLE NVIDIA OPTION (WIP)
  #BEGIN CHOOSING DESKTOP ENVIRONMENT
  echo "Choose your Desktop Environment"
  echo "0) Server [Tested]"
  echo "1) KDE Plasma [Tested]"
  echo "2) Gnome [Tested]"
  echo "3) LXDE [Unknown]"
  echo "4) Mate [Unknown]"
  echo "5) XFCE [Unknown]"
  while true; do
  read -p "Desktop Environment [0-5] = " de
  de=${de:-0} # Default to 0 if no input
  if [[ "$de" =~ ^[0-5]$ ]]; then
  echo "You selected option $de."
  break
  else
  echo "Invalid input. Please enter a number between 0 and 5."
  fi
  done
  #END CHOOSING DESKTOP ENVIRONMENT
  #BEGIN LIST OF AVAILIBLE PACSTRAP FOR EVERY DESKTOP ENVIRONMENT CHOICE
  if [ "${de,,}" = "0" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop git openssh reflector
  fi
  #KDE
  if [ "${de,,}" = "1" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector plasma-meta plasma-pa sddm konsole dolphin gwenview flatpak p7zip partitionmanager kcalc spectacle 
  fi
  #GNOME
  if [ "${de,,}" = "2" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector gnome gdm gnome-terminal
  fi
  #LXDE
  if [ "${de,,}" = "3" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector lxde gdm lxterminal
  fi
  #MATE
  if [ "${de,,}" = "4" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector mate gdm mate-terminal
  fi
  #XFCE
  if [ "${de,,}" = "5" ]; then
  pacstrap -K /mnt base $kernel mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector xfce4 lightdm xfce4-terminal
  fi
  #END LIST OF AVAILIBLE PACSTRAP FOR EVERY DESKTOP ENVIRONMENT CHOICE
  #BEGIN GENERATE FSTAB
  echo "Generating fstab"
  genfstab /mnt >> /mnt/etc/fstab
  #END GENERATE FSTAB
  #BEGIN MOVING BASHRC THEME AND PART2 OF SCRIPT
  echo "Moving required files to Arch-Chroot.."
  mv ./ArchInstallAssistantP2.sh /mnt/ArchInstallAssistantP2.sh
  mv ./archinstall_default.theme.sh /mnt/archinstall_default.theme.sh
  #END MOVING BASHRC THEME AND PART2 OF SCRIPT
  echo "After chrooting you will need to bash into part 2"
  echo "Location = /ArchInstallAssistantPart2.sh"
  read -p "Press ENTER to continue"
  echo "Chrooting into /mnt"
  arch-chroot /mnt
# Written by Nakildias
