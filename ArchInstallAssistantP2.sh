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

#THEME_DIR='/usr/share/grub/themes'
THEME_DIR='/boot/grub/themes'
THEME_NAME=''

function echo_title() {     echo -ne "\033[1;44;37m${*}\033[0m\n"; }
function echo_caption() {   echo -ne "\033[0;1;44m${*}\033[0m\n"; }
function echo_bold() {      echo -ne "\033[0;1;34m${*}\033[0m\n"; }
function echo_danger() {    echo -ne "\033[0;31m${*}\033[0m\n"; }
function echo_success() {   echo -ne "\033[0;32m${*}\033[0m\n"; }
function echo_warning() {   echo -ne "\033[0;33m${*}\033[0m\n"; }
function echo_secondary() { echo -ne "\033[0;34m${*}\033[0m\n"; }
function echo_info() {      echo -ne "\033[0;35m${*}\033[0m\n"; }
function echo_primary() {   echo -ne "\033[0;36m${*}\033[0m\n"; }
function echo_error() {     echo -ne "\033[0;1;31merror:\033[0;31m\t${*}\033[0m\n"; }
function echo_label() {     echo -ne "\033[0;1;32m${*}:\033[0m\t"; }
function echo_prompt() {    echo -ne "\033[0;36m${*}\033[0m "; }

function splash() {
    local hr
    hr=" **$(printf "%${#1}s" | tr ' ' '*')** "
    echo_title "${hr}"
    echo_title " * $1 * "
    echo_title "${hr}"
    echo
}

function check_root() {
    # Checking for root access and proceed if it is present
    ROOT_UID=0
    if [[ ! "${UID}" -eq "${ROOT_UID}" ]]; then
        # Error message
        echo_error 'Run me as root.'
        echo_info 'try sudo ./install.sh'
        exit 1
    fi
}

function select_theme() {
    themes=('Nobara' 'Custom' 'Cyberpunk' 'Cyberpunk_2077' 'Shodan' 'fallout' 'CyberRe' 'CyberSynchro' 'CyberEXS' 'CRT' 'BIOS' 'retro'  'Quit')

    PS3=$(echo_prompt '\nChoose The Theme You Want: ')
    select THEME_NAME in "${themes[@]}"; do
        case "${THEME_NAME}" in
            'Nobara')
                splash 'Installing Nobara Theme...'
                break;;
            'Custom')
                splash 'Installing Custom Theme...'
                break;;
            'Cyberpunk')
                splash 'Installing Cyberpunk Theme...'
                break;;
            'Cyberpunk_2077')
                splash 'Installing Cyberpunk_2077 Theme...'
                break;;
            'Shodan')
                splash 'Installing Shodan Theme...'
                break;;
            'fallout')
                splash 'Installing fallout Theme...'
                break;;
            'CyberRe')
                splash 'Installing CyberRe Theme...'
                break;;
            'CyberSynchro')
                splash 'Installing CyberSynchro Theme...'
                break;;
            'CyberEXS')
                splash 'Installing CyberEXS Theme...'
                break;;
            'CRT')
                splash 'Installing CRT Theme...'
                break;;
            'BIOS')
                splash 'Installing BIOS Theme...'
                break;;
            'retro')
                splash 'Installing retro Theme...'
                break;;
                'Quit')
                echo_info 'User requested exit...!'
                exit 0;;
            *) echo_warning "invalid option \"${REPLY}\"";;
        esac
    done
}

function backup() {
    # Backup grub config
    echo_info 'cp -an /etc/default/grub /etc/default/grub.bak'
    cp -an /etc/default/grub /etc/default/grub.bak
}

function install_theme() {
    # create themes directory if not exists
    if [[ ! -d "${THEME_DIR}/${THEME_NAME}" ]]; then
        # Copy theme
        echo_primary "Installing ${THEME_NAME} theme..."

        echo_info "mkdir -p \"${THEME_DIR}/${THEME_NAME}\""
        mkdir -p "${THEME_DIR}/${THEME_NAME}"

        echo_info "cp -a ./themes/\"${THEME_NAME}\"/* \"${THEME_DIR}/${THEME_NAME}\""
        cp -a ./themes/"${THEME_NAME}"/* "${THEME_DIR}/${THEME_NAME}"
    fi
}

function config_grub() {
    echo_primary 'Enabling grub menu'
    # remove default grub style if any
    echo_info "sed -i '/GRUB_TIMEOUT_STYLE=/d' /etc/default/grub"
    sed -i '/GRUB_TIMEOUT_STYLE=/d' /etc/default/grub

    echo_info "echo 'GRUB_TIMEOUT_STYLE=\"menu\"' >> /etc/default/grub"
    echo 'GRUB_TIMEOUT_STYLE="menu"' >> /etc/default/grub

    #--------------------------------------------------

    echo_primary 'Setting grub timeout to 10 seconds'
    # remove default timeout if any
    echo_info "sed -i '/GRUB_TIMEOUT=/d' /etc/default/grub"
    sed -i '/GRUB_TIMEOUT=/d' /etc/default/grub

    echo_info "echo 'GRUB_TIMEOUT=\"10\"' >> /etc/default/grub"
    echo 'GRUB_TIMEOUT="10"' >> /etc/default/grub

    #--------------------------------------------------

    echo_primary "Setting ${THEME_NAME} as default"
    # remove theme if any
    echo_info "sed -i '/GRUB_THEME=/d' /etc/default/grub"
    sed -i '/GRUB_THEME=/d' /etc/default/grub

    echo_info "echo \"GRUB_THEME=\"${THEME_DIR}/${THEME_NAME}/theme.txt\"\" >> /etc/default/grub"
    echo "GRUB_THEME=\"${THEME_DIR}/${THEME_NAME}/theme.txt\"" >> /etc/default/grub
    
    #--------------------------------------------------

    echo_primary 'Setting grub graphics mode to auto'
    # remove default timeout if any
    echo_info "sed -i '/GRUB_GFXMODE=/d' /etc/default/grub"
    sed -i '/GRUB_GFXMODE=/d' /etc/default/grub

    echo_info "echo 'GRUB_GFXMODE=\"auto\"' >> /etc/default/grub"
    echo 'GRUB_GFXMODE="auto"' >> /etc/default/grub   
}

function update_grub() {
    # Update grub config
    echo_primary 'Updating grub config...'
    if [[ -x "$(command -v update-grub)" ]]; then
        echo_info 'update-grub'
        update-grub

    elif [[ -x "$(command -v grub-mkconfig)" ]]; then
        echo_info 'grub-mkconfig -o /boot/grub/grub.cfg'
        grub-mkconfig -o /boot/grub/grub.cfg

    elif [[ -x "$(command -v grub2-mkconfig)" ]]; then
        if [[ -x "$(command -v zypper)" ]]; then
            echo_info 'grub2-mkconfig -o /boot/grub2/grub.cfg'
            grub2-mkconfig -o /boot/grub2/grub.cfg

        elif [[ -x "$(command -v dnf)" ]]; then
            echo_info 'grub2-mkconfig -o /boot/grub2/grub.cfg'
            grub2-mkconfig -o /boot/grub2/grub.cfg
        fi
    fi
}

function main() {
    splash 'GRUB Theme Changer'

    check_root
    select_theme

    install_theme

    config_grub
    update_grub

    echo_success 'Boot Theme Update Successful!'
}

main
#Credits goes to ChrisTitus for the grub themer
#This version is also updated by thesacredsin
fi

  
  echo "Almost done please follow the next instruction"
  echo "Enter [exit] to leave chroot and then shutdown using [shutdown now]"
# Written by Nakildias
