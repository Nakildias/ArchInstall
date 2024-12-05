#!/bin/bash
  clear
  echo "Welcome to Arch Install Assistant (Part 2/3)"
  sleep 1
  echo "Setting up Time Zone"
  echo "Enter Region"
  echo "Example & Default = America"
  read -p "Region : " Region
  Region=${Region:-America}
  echo "Enter City"
  echo "Example & Default = New_York"
  read -p "City : " City
  City=${City:-New_York}
  ln -sf /usr/share/zoneinfo/$Region/$City /etc/localtime
  echo "Now using $Region/$City"
  read -p "Use default locale? default=en_US.UTF-8 [y/n] : " usedefaultlocale
  if [ "${usedefaultlocale,,}" = "y" ]; then
  touch /etc/locale.conf
  sed -i 171s/.*/en_US.UTF-8\ UTF-8/ /etc/locale.gen
  sed -i 1s/.*/LANG=en_US.UTF-8/ /etc/locale.conf
  fi
  if [ "${usedefaultlocale,,}" = "n" ]; then
  echo "You will now need to uncomment your locale"
  read -p "Press ENTER when ready"
  nano /etc/locale.gen
  echo "Add LANG=en_US.UTF-8 to the following file"
  read -p "Press ENTER when ready"
  nano /etc/locale.conf
  echo "Done"
  fi
  echo "Generating Locale..."
  locale-gen
  read -p "hostname : " hostname
  if [ -f "/etc/hostname" ]; then
  echo "Removing /etc/hostname because it already exists"
  rm /etc/hostname
  fi
  touch /etc/hostname
  echo "$hostname" > /etc/hostname
  echo "/etc/hostname was created with hostname [$hostname]"
  echo "Enter password for root"
  passwd
  echo "Creating Regular User"
  read -p "Enter your desired username : " username
  useradd -m -G wheel -s /bin/bash $username
  passwd $username
  echo "Enabling SU Permissions for $username"
  sed -i 125s/#\ // /etc/sudoers
  #fdisk -l
  #read -p "Disk for grub example sda = " disk
  #BEGIN ENABLE PARALLEL DOWNLOADS OPTION
  while true; do
  read -p "Enable Parallel Downloads for pacstrap? [y/n] = " Parallel
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

  while true; do
  read -p "Enable Network Manager Service? [y/n] = " nm
  case "${nm,,}" in
  y)
  echo "Network Manager service enabled."
  systemctl enable NetworkManager
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
  systemctl enable sshd
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

  if command -v sddm &> /dev/null; then
  while true; do
  read -p "Enable SDDM Service? [y/n] = " sddm
  case "${sddm,,}" in
  y)
  echo "SDDM service enabled."
  systemctl enable sddm
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

  if command -v gdm &> /dev/null; then
  while true; do
  read -p "Enable GDM Service? [y/n] = " gdm
  case "${gdm,,}" in
  y)
  echo "GDM service enabled."
  systemctl enable gdm
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
  
  if command -v lightdm &> /dev/null; then
  while true; do
  read -p "Enable LightDM Service? [y/n] = " lightdm
  case "${lightdm,,}" in
  y)
  echo "LightDM service enabled."
  systemctl enable lightdm
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
  bash -c "$(curl -fsSL https://raw.githubusercontent.com/ohmybash/oh-my-bash/master/tools/install.sh)" --unattended
  sed -i 12s/.*/OSH_THEME="archinstall_default"/ ~/.bashrc
  echo "oh-my-bash installed for user root"
  echo "copying root config to $username"
  cp -rf ~/.* /home/$username/
  mkdir /home/$username/.oh-my-bash/themes/archinstall_default
  cp ./archinstall_default.theme.sh /home/$username/.oh-my-bash/themes/archinstall_default/archinstall_default.theme.sh
  mkdir /root/.oh-my-bash/themes/archinstall_default
  mv ./archinstall_default.theme.sh /root/.oh-my-bash/themes/archinstall_default/archinstall_default.theme.sh
  chmod +rwx /home/$username/.*
  sed -i "8c export OSH='/home/$username/.oh-my-bash'" /home/$username/.bashrc
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
  grub-install --efi-directory=/boot
  echo "Configuring Grub /boot/grub/grub.cfg"
  grub-mkconfig -o /boot/grub/grub.cfg

  while true; do
  read -p "Change Grub Theme? [y/n] = " grub
  case "${grub,,}" in
  y)
  echo "Changing Grub Theme."
  git clone https://github.com/RomjanHossain/Grub-Themes.git
  cd ./Grub-Themes
  bash ./install.sh
  #Credits to RomjanHossain
  break
  ;;
  n)
  echo "Keeping current unthemed Grub."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  clear
  echo "___________________________________________________________________"
  echo "             \/ \/ \/ \/ DO THIS RIGHT NOW \/ \/ \/"
  echo "Input [exit] to continue & then input bash ./ArchInstallAssistantP3.sh"
# Written by Nakildias
