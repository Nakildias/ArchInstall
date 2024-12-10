#!/bin/bash

  while true; do
  read -p "Install the Arch Grub Theme? [y/n] = " gt
  case "${gt,,}" in
  y)
  echo "Grub Theme will be installed."
  git clone https://github.com/Nakildias/Grub-Themes.git
  sudo bash ./Grub-Themes/install.sh
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
