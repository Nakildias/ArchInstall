#!/bin/bash
  clear
  echo "Welcome to Arch Install by Nakildias"
  echo "Checking EFI"
  if [ ! -e "/sys/firmware/efi/fw_platform_size" ]; then
  echo "EFI firmware not available"
  echo "Fix this by enabling UEFI in your bios"
  while true; do
  sleep 60
  done
  fi
  echo "EFI firmware available"
  read -p "Press ENTER to continue"
  clear
  
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
    echo 1 | parted /dev/$disk rm
  echo "All existing partitions on $disk were deleted."
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
  if [[ "$disk" == *"nvme"* ]]; then
  echo "The disk type is NVMe"
  Partition_Boot=${Partition_Boot:-$disk\p1}
  Partition_Swap=${Partition_Swap:-$disk\p2}
  Partition_Root=${Partition_Root:-$disk\p3}
  else
  echo "The disk type is not NVMe"
  Partition_Boot=${Partition_Boot:-$disk\1}
  Partition_Swap=${Partition_Swap:-$disk\2}
  Partition_Root=${Partition_Root:-$disk\3}
  fi
  #while true; do
  #read -p "Is the targeted drive nvme? y/n = " nvme
  #case "${nvme,,}" in
  #y)
  #echo "NVME = True."
  #Partition_Boot=${Partition_Boot:-$disk\p1}
  #Partition_Swap=${Partition_Swap:-$disk\p2}
  #Partition_Root=${Partition_Root:-$disk\p3}
  #break
  #;;
  #n)
  #echo "NVME = False."
  #Partition_Boot=${Partition_Boot:-$disk\1}
  #Partition_Swap=${Partition_Swap:-$disk\2}
  #Partition_Root=${Partition_Root:-$disk\3}
  #break
  #;;
  #*)
  #echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  #;;
  #esac
  #done
  #Partition_Boot=${Partition_Boot:-$disk\1}
  #Partition_Swap=${Partition_Swap:-$disk\2}
  #Partition_Root=${Partition_Root:-$disk\3}
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

######### EXPERIMENTAL ##########

  echo "Setting up Time Zone"
  echo "Enter Region"
  echo "Example & Default = America"
  read -p "Region : " Region
  Region=${Region:-America}
  echo "Enter City"
  echo "Example & Default = New_York"
  read -p "City : " City
  City=${City:-New_York}
  arch-chroot /mnt ln -sf /usr/share/zoneinfo/$Region/$City /etc/localtime
  echo "Now using $Region/$City"
  read -p "Use default locale? default=en_US.UTF-8 [y/n] : " usedefaultlocale
  if [ "${usedefaultlocale,,}" = "y" ]; then
  arch-chroot /mnt touch /etc/locale.conf
  arch-chroot /mnt sed -i 171s/.*/en_US.UTF-8\ UTF-8/ /etc/locale.gen
  arch-chroot /mnt sed -i 1s/.*/LANG=en_US.UTF-8/ /etc/locale.conf
  fi
  if [ "${usedefaultlocale,,}" = "n" ]; then
  echo "You will now need to uncomment your locale"
  read -p "Press ENTER when ready"
  arch-chroot /mnt nano /etc/locale.gen
  echo "Add LANG=en_US.UTF-8 to the following file"
  read -p "Press ENTER when ready"
  arch-chroot /mnt nano /etc/locale.conf
  echo "Done"
  fi
  echo "Generating Locale..."
  arch-chroot /mnt locale-gen
  read -p "hostname : " hostname
  if [ -f "/etc/hostname" ]; then
  echo "Removing /etc/hostname because it already exists"
  arch-chroot /mnt rm /etc/hostname
  fi
  arch-chroot /mnt touch /etc/hostname
  echo "$hostname" > /etc/hostname
  echo "/etc/hostname was created with hostname [$hostname]"
  echo "Enter password for root"
  arch-chroot /mnt passwd
  echo "Creating Regular User"
  read -p "Enter your desired username : " username
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash $username
  arch-chroot /mnt passwd $username
  echo "Enabling SU Permissions for $username"
  arch-chroot /mnt sed -i 125s/#\ // /etc/sudoers
  #fdisk -l
  #read -p "Disk for grub example sda = " disk
  #BEGIN ENABLE PARALLEL DOWNLOADS OPTION
  #while true; do
  #read -p "Enable Parallel Downloads for pacstrap? [y/n] = " Parallel
  #case "${Parallel,,}" in
  #y)
  #echo "Parallel Downloads enabled."
  #break
  #;;
  #n)
  #echo "Parallel Downloads not enabled."
  #break
  #;;
  #*)
  #echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  #;;
  #esac
  #done
  #END ENABLE PARALLEL DOWNLOADS OPTION
  #BEGIN CHOOSING PARALLEL THREADS COUNT
  #if [ "${Parallel,,}" = "y" ]; then
  #while true; do
  #read -p "How many download threads? 1-10 (default = 5) = " Parallel_Value
  #Parallel_Value=${Parallel_Value:-5}
  # Check if input is a valid number between 1 and 10
  #if [[ "$Parallel_Value" =~ ^[0-9]+$ ]] && ((Parallel_Value >= 1 && Parallel_Value <= 10)); then
  #break
  #else
  #echo "Error: Please enter a number between 1 and 10."
  #fi
  #done
  #echo "You chose $Parallel_Value download threads."
  if [ "${Parallel,,}" = "y" ]; then
  arch-chroot /mnt sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  echo "Setting downloads threads to $Parallel_Value for $username"
  fi
  #END CHOOSING PARALLEL THREADS COUNT

  while true; do
  read -p "Enable Network Manager Service? [y/n] = " nm
  case "${nm,,}" in
  y)
  echo "Network Manager service enabled."
  arch-chroot /mnt systemctl enable NetworkManager
  break
  ;;
  n)
  echo "NetworkManager service not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Enable SSH Service? [y/n] = " ssh
  case "${ssh,,}" in
  y)
  echo "SSH service enabled."
  arch-chroot /mnt systemctl enable sshd
  break
  ;;
  n)
  echo "SSH service not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  if [[ $de =~ [1] ]]; then
  else
  while true; do
  read -p "Enable SDDM Service? [y/n] = " sddm
  case "${sddm,,}" in
  y)
  echo "SDDM service enabled."
  arch-chroot /mnt systemctl enable sddm
  break
  ;;
  n)
  echo "SDDM service not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
  fi

  #if command -v gdm &> /dev/null; then
  # Check if gdm service exists
  if [[ $de =~ [234] ]]; then
  echo "GDM Detected."
  else
  while true; do
  read -p "Enable GDM Service? [y/n] = " gdm
  case "${gdm,,}" in
  y)
  echo "GDM service enabled."
  arch-chroot /mnt systemctl enable gdm
  break
  ;;
  n)
  echo "GDM service not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
  fi
  
  
  if [[ $de =~ [5] ]]; then
  else
  while true; do
  read -p "Enable LightDM Service? [y/n] = " lightdm
  case "${lightdm,,}" in
  y)
  echo "LightDM service enabled."
  arch-chroot /mnt systemctl enable lightdm
  break
  ;;
  n)
  echo "LightDM service not enabled."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
  fi

  while true; do
  read -p "Install oh-my-bash? [y/n] = " omb
  case "${omb,,}" in
  y)
  echo "Installing oh-my-bash..."
  arch-chroot /mnt bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
  arch-chroot /mnt sed -i 12s/.*/OSH_THEME="archinstall_default"/ ~/.bashrc
  echo "oh-my-bash installed for user root"
  echo "copying root config to $username"
  cp -rf /mnt/root/.* /mnt/home/$username/
  mkdir /mnt/home/$username/.oh-my-bash/themes/archinstall_default
  cp /root/ArchInstall/archinstall_default.theme.sh /mnt/home/$username/.oh-my-bash/themes/archinstall_default/archinstall_default.theme.sh
  mkdir /mnt/root/.oh-my-bash/themes/archinstall_default
  cp /root/ArchInstall/archinstall_default.theme.sh /mnt/root/.oh-my-bash/themes/archinstall_default/archinstall_default.theme.sh
  chmod +rwx /mnt/home/$username/.*
  sed -i "8c export OSH='/home/$username/.oh-my-bash'" /mnt/home/$username/.bashrc
  echo "oh-my-bash set to use archinstall_default theme"
  echo "More bash themes can be found at default for this install is [archinstall_default]"
  echo "https://github.com/ohmybash/oh-my-bash/tree/master/themes"
  echo "Theme config is located at ~/.bashrc line #12"
  break
  ;;
  n)
  echo "oh-my-bash won't be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
  
  echo "Installing Grub to /boot"
  arch-chroot /mnt grub-install --efi-directory=/boot
  echo "Configuring Grub /boot/grub/grub.cfg"
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg

  #arch-chroot /mnt git clone https://github.com/RomjanHossain/Grub-Themes.git
  #arch-chroot /mnt bash /Grub-Themes/install.sh


  clear
  read -p "Press ENTER to finish the installation"
  shutdown now
# Written by Nakildias
