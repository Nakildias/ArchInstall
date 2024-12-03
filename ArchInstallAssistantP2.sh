#!/bin/bash
  clear
  echo "Welcome to Arch Install Assistant (Part 2/2)"
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
  read -p "Enable Parallel Downloads for pacman? [y/n] : " Parallel
  if [ "${Parallel,,}" = "y" ]; then
  read -p "How many download threads? [default = 5] : " Parallel_Value
  Parallel_Value=${Parallel_Value:-5}
  sed -i 37s/.*/ParallelDownloads\ =\ $Parallel_Value/ /etc/pacman.conf
  fi
  read -p "Enable NetworkManager? [y/n] : " nm
  if [ "${nm,,}" = "y" ]; then
  systemctl enable NetworkManager
  fi
  read -p "Enable SSH? [y/n] : " ssh
  if [ "${ssh,,}" = "y" ]; then
  systemctl enable sshd
  fi
  
  if command -v sddm &> /dev/null; then
  read -p "Enable SDDM? [y/n] : " sddm
  if [ "${sddm,,}" = "y" ]; then
  systemctl enable sddm
  fi
  fi
  
  if command -v gdm &> /dev/null; then
  read -p "Enable GDM? [y/n] : " gdm
  if [ "${gdm,,}" = "y" ]; then
  systemctl enable gdm
  fi  
  fi
  
  if command -v lightdm &> /dev/null; then
  read -p "Enable LightDM? [y/n] : " lightdm
  if [ "${lightdm,,}" = "y" ]; then
  systemctl enable lightdm
  fi
  fi
  
  read -p "Install oh-my-bash? [y/n] : " omb
  if [ "${omb,,}" = "y" ]; then
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
  echo "More bash themes can be found at default for this install is [lamba]"
  echo "https://github.com/ohmybash/oh-my-bash/tree/master/themes"
  echo "Theme config is located at ~/.bashrc line #12"
  fi
  
  echo "Installing Grub to /boot"
  grub-install --efi-directory=/boot
  echo "Configuring Grub /boot/grub/grub.cfg"
  grub-mkconfig -o /boot/grub/grub.cfg


  read -p "Change Grub Theme? [y/n] : " gt
  if [ "${gt,,}" = "y" ]; then
  git clone https://github.com/thesacredsin/grub_themes
  cd grub_themes
  sudo ./install.sh
  #Credits to ChrisTitus & thesacredsin for the grub theme script"
  fi
  
  echo "Almost done please follow the next instruction"
  echo "Enter [exit] to leave chroot and then shutdown using [shutdown now]"
# Written by Nakildias
