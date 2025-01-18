#!/bin/bash
  #CHECK IF SYSTEM IS USING EFI
  echo "Welcome to Arch Install by Nakildias"
  echo "Checking EFI"
  if [ ! -e "/sys/firmware/efi/fw_platform_size" ]; then
  echo -e "\033[0;31mEFI firmware not available\033[0m"
  echo "Fix this by enabling UEFI in your bios"
  while true; do
  sleep 60
  done
  fi
  echo -e "\033[0;32mEFI firmware available\033[0m"
  read -p "Press ENTER to continue"
  
  #RETRIEVE LIST OF DISKS
  valid_disks=($(fdisk -l | awk '/^Disk \/dev\// {gsub(":", "", $2); print $2}' | cut -d'/' -f3))

  #QUIT IF NO DISK ARE PRESENT
  if [ ${#valid_disks[@]} -eq 0 ]; then
  echo -e "\033[0;31mNo valid disks found. Exiting.\033[0m"
  exit 1
  fi

  #DISPLAY FOUND DISKS TO USER
  echo -e "\033[0;34mAvailable disks:\033[0m ${valid_disks[@]}"

  #ASK USER FOR THE DISK TO USE
  while true; do
  read -p "Disk = " disk
  if [[ " ${valid_disks[@]} " =~ " ${disk} " ]]; then
  echo -e "\033[0;32mYou selected a valid disk:\033[0m $disk"
  break
  else
  echo -e "\033[0;31mInvalid disk. Please try again.\033[0m"
  fi
  done

  #CONFIRM IF USER AGREE TO ERASE THE SELECTED DISK
  echo -e "\033[0;31mWarning: This will erase all data on /dev/$disk.\033[0m"
  read -p "Are you sure? (yes/no): " confirmation
  if [[ "$confirmation" != "yes" ]]; then
  echo -e "\033[0;31mOperation canceled.\033[0m"
  exit 1
  fi

  #DELETE EXISTING PARTITION ON THE SELECTED DISK
  echo "Checking for existing partitions on /dev/$disk..."
  partitions=($(lsblk -np | grep "/dev/$disk" | awk '{print $1}'))
  if [ ${#partitions[@]} -gt 0 ]; then
  echo -e "\033[0;32mFound partitions:\033[0m ${partitions[@]}"
  echo 1 | parted /dev/$disk rm
  echo -e "\033[0;32mAll existing partitions on\033[0m $disk \033[0;32mwere deleted.\033[0m"
  else
  echo -e "\033[0;31mNo existing partitions found on /dev/$disk.\033[0m"
  fi


  #ASK USER FOR BOOT SIZE
  while true; do
  read -p "Enter Boot Size (Should be between 512M & 2G): " BootSize
  if [[ $BootSize =~ ^[0-9]+[MG]$ ]]; then
  echo -e "\033[0;32mBoot size set to:\033[0m $BootSize"
  break
  else
  echo -e "\033[0;31mInvalid boot size. Please enter a size in the format '2G' or '512M'.\033[0m"
  fi
  done

  #ASK USER FOR SWAP SIZE
  #NOTE//NEED TO MAKE THIS AN OPTION
  while true; do
  read -p "Enter Swap Size (e.g., 2G, 512M): " SwapSize
  if [[ $SwapSize =~ ^[0-9]+[MG]$ ]]; then
  echo -e "\033[0;32mSwap size set to:\033[0m $SwapSize"
  break
  else
  echo -e "\033[0;31mInvalid swap size. Please enter a size in the format '2G' or '512M'.\033[0m"
  fi
  done

  #PARTITIONING THE SELECTED DISK
  echo "Partitioning /dev/$disk..."
  (
  echo g # Create a new GPT partition table
  echo n # New partition
  echo 1 # Partition number 1
  echo   # Default - start at beginning of disk
  echo +$BootSize # End at $BootSize

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

  #DISPLAY PARTITION TABLE OF THE SELECTED DISK
  echo -e "\033[0;32mPartitioning complete.\033[0m"
  echo "Updated disk layout:"
  fdisk -l /dev/$disk

  #CHECK IF DISK IS OF TYPE NVME
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

  #PARTITIONING THE DISK
  fdisk -l
  echo ""
  echo "$Partition_Boot (BOOT) | $Partition_Swap (SWAP) | $Partition_Root (ROOT)"
  echo ""
  echo "Partitions above will be formated to their required filesystem."
  read -p "Press ENTER if everything seems OK"
  mkfs.fat -F 32 /dev/$Partition_Boot
  mkswap /dev/$Partition_Swap
  mkfs.ext4 /dev/$Partition_Root
  echo -e "\033[0;32mPartitioning Done\033[0m"


  #MOUNTING THE PARTITIONS
  echo "Mounting partitions..."
  mount /dev/$Partition_Root /mnt
  mount --mkdir /dev/$Partition_Boot /mnt/boot
  swapon /dev/$Partition_Swap
  echo -e "\033[0;32mMounting Completed\033[0m"

  #UPDATE KEYRING TO FIX CORRUPTED PACKAGE ERROR
  echo "Updating archlinux-keyring..."
  pacman -Sy archlinux-keyring --noconfirm

  #PACMAN MULTI-THREAD CONFIGURATION
  while true; do
  read -p "Enable Parallel Downloads for pacstrap and the arch install? y/n = " Parallel
  case "${Parallel,,}" in
  y)
  echo -e "\033[0;32mParallel Downloads enabled.\033[0m"
  break
  ;;
  n)
  echo -e "\033[0;32mParallel Downloads not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done
  if [ "${Parallel,,}" = "y" ]; then
  while true; do
  read -p "How many download threads? 1-10 (default = 5) = " Parallel_Value
  Parallel_Value=${Parallel_Value:-5}
  # Check if input is a valid number between 1 and 10
  if [[ "$Parallel_Value" =~ ^[0-9]+$ ]] && ((Parallel_Value >= 1 && Parallel_Value <= 10)); then
  break
  else
  echo -e "\033[0;31mError: Please enter a number between 1 and 10.\033[0m"
  fi
  done
  echo "You chose $Parallel_Value download threads."
  sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  fi

  #ASK USER TO CHOOSE KERNEL
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
  echo -e "\033[0;31mInvalid choice:\033[0m '$kernel'\033[0;31m. Please try again.\033[0m"
  ;;
  esac
  done
  

  #ASK USER TO CHOOSE DESKTOP ENVIRONMENT
  echo "Choose your Desktop Environment"
  echo -e "0) Server \033[0;32m[Tested]\033[0m"
  echo -e "1) KDE Plasma \033[0;32m[Tested]\033[0m"
  echo -e "2) Gnome \033[0;32m[Tested]\033[0m"
  echo -e "3) LXDE \033[0;31m[Unknown]\033[0m"
  echo -e "4) Mate \033[0;31m[Unknown]\033[0m"
  echo -e "5) XFCE \033[0;31m[Unknown]\033[0m"
  while true; do
  read -p "Desktop Environment [0-5] = " de
  de=${de:-0} # Default to 0 if no input
  if [[ "$de" =~ ^[0-5]$ ]]; then
  echo "You selected option $de."
  break
  else
  echo -e "\033[0;31mInvalid input. Please enter a number between 0 and 5.\033[0m"
  fi
  done
  
  #DESKTOP ENVIRONMENT LIST
  if [ "${de,,}" = "0" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop git openssh reflector
  fi
  #KDE
  if [ "${de,,}" = "1" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector plasma-meta plasma-pa sddm konsole dolphin gwenview flatpak p7zip partitionmanager kcalc spectacle 
  fi
  #GNOME
  if [ "${de,,}" = "2" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector gnome gdm gnome-terminal
  fi
  #LXDE
  if [ "${de,,}" = "3" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector lxde gdm lxterminal
  fi
  #MATE
  if [ "${de,,}" = "4" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector mate gdm mate-terminal
  fi
  #XFCE
  if [ "${de,,}" = "5" ]; then
  pacstrap -K /mnt base $kernel amd-ucode intel-ucode mesa linux-firmware base-devel nano efibootmgr networkmanager grub wget fastfetch bashtop firefox kate git openssh reflector xfce4 lightdm xfce4-terminal lightdm-gtk-greeter lightdm-gtk-greeter-settings
  fi

  #GENERATE FSTAB
  echo "Generating fstab"
  genfstab /mnt >> /mnt/etc/fstab

  #TIMEZONE SETUP
  #NOTE: NEEDS SOME WORK...
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

  #ASK USER FOR HOSTNAME
  read -p "hostname : " hostname
  if [ -f "/etc/hostname" ]; then
  echo "Removing /etc/hostname because it already exists"
  arch-chroot /mnt rm /etc/hostname
  fi
  arch-chroot /mnt touch /etc/hostname
  echo "$hostname" > /etc/hostname
  echo "/etc/hostname was created with hostname [$hostname]"

  #ASK USER FOR ROOT PASSWORD
  echo "Enter password for root"
  arch-chroot /mnt passwd

  #ASK USER FOR A USERNAME, PASSWORD & ENABLE SUDO PERMISSION FOR USER
  echo "Creating Regular User"
  read -p "Enter your desired username : " username
  arch-chroot /mnt useradd -m -G wheel -s /bin/bash $username
  arch-chroot /mnt passwd $username
  echo "Enabling SU Permissions for $username"
  arch-chroot /mnt sed -i 125s/#\ // /etc/sudoers

  #SET MULTI-THREAD DOWNLOAD OPTION WITH VALUES ASKED EARLIER
  if [ "${Parallel,,}" = "y" ]; then
  arch-chroot /mnt sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  echo "Setting downloads threads to $Parallel_Value for $username"
  fi
  
  #ASK USER IF HE/SHE WANTS TO ENABLE VARIOUS SERVICES
  while true; do
  read -p "Enable Network Manager Service? [y/n] = " nm
  case "${nm,,}" in
  y)
  echo -e "\033[0;32mNetwork Manager service enabled.\033[0m"
  arch-chroot /mnt systemctl enable NetworkManager
  break
  ;;
  n)
  echo -e "\033[0;32mNetworkManager service not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done

  while true; do
  read -p "Enable SSH Service? [y/n] = " ssh
  case "${ssh,,}" in
  y)
  echo -e "\033[0;32mSSH service enabled.\033[0m"
  arch-chroot /mnt systemctl enable sshd
  break
  ;;
  n)
  echo -e "\033[0;32mSSH service not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done

  if [[ $de =~ [1] ]]; then
  while true; do
  read -p "Enable SDDM Service? [y/n] = " sddm
  case "${sddm,,}" in
  y)
  echo -e "\033[0;32mSDDM service enabled.\033[0m"
  arch-chroot /mnt systemctl enable sddm
  break
  ;;
  n)
  echo -e "\033[0;32mSDDM service not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done
  fi

  if [[ $de =~ [234] ]]; then
  while true; do
  read -p "Enable GDM Service? [y/n] = " gdm
  case "${gdm,,}" in
  y)
  echo -e "\033[0;32mGDM service enabled.\033[0m"
  arch-chroot /mnt systemctl enable gdm
  break
  ;;
  n)
  echo -e "\033[0;32mGDM service not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done
  fi
  
  if [[ $de =~ [5] ]]; then
  while true; do
  read -p "Enable LightDM Service? [y/n] = " lightdm
  case "${lightdm,,}" in
  y)
  echo -e "\033[0;32mLightDM service enabled.\033[0m"
  arch-chroot /mnt systemctl enable lightdm
  break
  ;;
  n)
  echo -e "\033[0;32mLightDM service not enabled.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done
  fi

  #ASK USER IF HE/SHE WANTS OH-MY-BASH
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
  echo -e "\033[0;32moh-my-bash won't be installed.\033[0m"
  break
  ;;
  *)
  echo -e "\033[0;31mInvalid input. Please enter 'y' for yes or 'n' for no.\033[0m"
  ;;
  esac
  done

  #INSTALLING GRUB FOR EFI
  echo "Installing Grub to /boot"
  arch-chroot /mnt grub-install --efi-directory=/boot
  echo "Configuring Grub /boot/grub/grub.cfg"
  arch-chroot /mnt grub-mkconfig -o /boot/grub/grub.cfg
  echo -e "\033[0;32mGrub Installed.\033[0m"

  #FINISH INSTALLATION BY PRESSING "ENTER"
  read -p "Press ENTER to finish the installation"
  shutdown now
  # Written by Nakildias
