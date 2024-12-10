#!/bin/bash

  while true; do
  read -p "Install the Arch Grub Theme? [y/n] = " gt
  case "${gt,,}" in
  y)
  echo "Grub Theme will be installed."
  git clone https://github.com/Nakildias/ArchGrubTheme.git
  sudo bash ./ArchGrubTheme/install.sh
  break
  ;;
  n)
  echo "Grub Theme will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Install AUR Helper (yay)? [y/n] = " yay
  case "${yay,,}" in
  y)
  echo "yay will be installed."
  git clone https://aur.archlinux.org/yay.git
  cd yay
  makepkg -si
  break
  ;;
  n)
  echo "yay will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Install QEMU KVM & Virtual Machine Manager? [y/n] = " vm
  case "${vm,,}" in
  y)
  echo "QEMU KVM + VM Manager will be installed."
  sudo pacman -Sy qemu-full virt-manager libvirt dnsmasq
  echo "Enabling libvirt service"
  sudo systemctl enable libvirtd
  echo "Starting libvirt service"
  sudo systemctl start libvirtd
  echo "Enabling & starting default network"
  sudo virsh net-autostart default
  sudo virsh net-start default
  break
  ;;
  n)
  echo "QEMU KVM + VM Manager will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Install LibreOffice? [y/n] = " lo
  case "${lo,,}" in
  y)
  echo "LibreOffice will be installed."
  sudo pacman -Sy libreoffice-fresh
  break
  ;;
  n)
  echo "LibreOffice will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Install p7zip-gui from aur? [y/n] = " zip
  case "${zip,,}" in
  y)
  echo "p7zip-gui will be installed."
  yay p7zip-gui
  break
  ;;
  n)
  echo "p7zip-gui will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done

  while true; do
  read -p "Install MacSequoia Theme?(REQUIRES KDE) [y/n] = " kt
  case "${kt,,}" in
  y)
  echo "MacSequoia will be installed."
  git clone https://github.com/vinceliuice/MacSonoma-kde.git
  sudo bash ./MacSonoma-kde/install.sh
  break
  ;;
  n)
  echo "MacSequoia will not be installed."
  break
  ;;
  *)
  echo "Invalid input. Please enter 'y' for yes or 'n' for no."
  ;;
  esac
  done
