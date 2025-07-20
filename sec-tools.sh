#!/bin/bash

# ==============================================================================
#
# Arch Linux Power-User & Security Tool Installer
#
# This script installs a selection of useful security, networking, and
# general utility tools inspired by Kali Linux. It uses the official
# Arch repositories and the Arch User Repository (AUR) with 'yay'.
#
# It also creates a file named 'utils-info.txt' in your home directory
# with descriptions and example usage for each installed package.
#
# ==============================================================================

# ------------------------------------------------------------------------------
# Script Configuration & Colors
# ------------------------------------------------------------------------------

# Exit immediately if a command exits with a non-zero status.
set -e

# Define colors for output messages
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# --- Function to print colored messages ---
print_message() {
    local color=$1
    local message=$2
    echo -e "${color}${message}${NC}"
}

# ------------------------------------------------------------------------------
# Initial System Update
# ------------------------------------------------------------------------------

print_message "$BLUE" "Updating system packages. This may take a few minutes..."
sudo pacman -Syu --noconfirm

print_message "$GREEN" "System update complete."

# ------------------------------------------------------------------------------
# AUR Helper Installation (yay)
# ------------------------------------------------------------------------------

# We need an AUR helper to install packages not in the official repositories.
# We'll use 'yay', a popular and efficient choice written in Go.
if ! command -v yay &> /dev/null; then
    print_message "$BLUE" "AUR helper 'yay' not found. Installing it now..."
    # Dependencies for building packages
    sudo pacman -S --needed base-devel git go --noconfirm
    
    # Clone and install yay
    git clone https://aur.archlinux.org/yay.git /tmp/yay
    (cd /tmp/yay && makepkg -si --noconfirm)
    rm -rf /tmp/yay
    
    print_message "$GREEN" "'yay' has been installed successfully."
else
    print_message "$GREEN" "AUR helper 'yay' is already installed."
fi


# ------------------------------------------------------------------------------
# Package Installation
# ------------------------------------------------------------------------------

# --- Official Repository Packages ---
print_message "$BLUE" "Installing tools from the official Arch repositories..."

# List of packages to install from official repos
OFFICIAL_PACKAGES=(
    # Network Tools
    nmap           # The king of network scanning
    wireshark-qt   # Powerful network protocol analyzer
    tcpdump        # Command-line packet analyzer
    net-tools      # Includes netstat, arp, route, etc.
    dnsutils       # Includes dig, nslookup
    openbsd-netcat # The 'swiss army knife' for TCP/IP
    socat          # Advanced netcat alternative
    iptables   # Firewall management

    # Web & Vulnerability
    nikto          # Web server scanner
    sqlmap         # SQL injection detection and exploitation
    gobuster       # Directory/file & DNS busting tool
    wpscan         # WordPress vulnerability scanner

    # Password Cracking
    john           # John the Ripper, a fast password cracker
    hashcat        # Advanced GPU-based password cracker
    hydra          # Parallelized login cracker

    # Wireless Tools
    aircrack-ng    # WiFi security auditing suite
    reaver         # WPS brute force attack tool

    # Forensics & Reverse Engineering
    binwalk        # Firmware analysis tool
    ghidra         # Software reverse engineering framework (NSA)
    radare2        # Reverse engineering framework
    gdb            # The GNU Debugger
    strace         # System call tracer
    ltrace         # Library call tracer
    foremost       # File recovery tool
    
    # General Utilities
    htop           # Interactive process viewer
    fastfetch      # A neofetch-like tool for fetching system information but much faster
    tmux           # Terminal multiplexer
    zsh            # Powerful shell
    exploitdb      # Exploit Database archive
)

sudo pacman -S --needed "${OFFICIAL_PACKAGES[@]}" --noconfirm
print_message "$GREEN" "Official repository packages installed."


# --- AUR Packages ---
print_message "$BLUE" "Installing tools from the Arch User Repository (AUR)..."

# List of packages to install from AUR
AUR_PACKAGES=(
    metasploit              # The world's most used penetration testing framework
    burpsuite               # Web vulnerability scanner and proxy (community edition)
    dirb                    # Web content scanner
    hashcat-utils           # Utilities for hashcat
    wfuzz                   # Web application fuzzer
    ffuf                    # Fast web fuzzer written in Go
#    bloodhound              # Active Directory trust relationship analysis (Doesn't work rn)
    impacket                # Python classes for working with network protocols
    volatility3-git         # Memory forensics framework
)

yay -S --needed "${AUR_PACKAGES[@]}" --noconfirm
print_message "$GREEN" "AUR packages installed."


# ------------------------------------------------------------------------------
# Create Utility Information File
# ------------------------------------------------------------------------------
print_message "$BLUE" "Creating utility information file at ~/utils-info.txt..."

INFO_FILE=~/utils-info.txt

# Create or overwrite the file with a header
echo "==================================================" > "$INFO_FILE"
echo "      Installed Power-User & Security Tools       " >> "$INFO_FILE"
echo "==================================================" >> "$INFO_FILE"
echo "" >> "$INFO_FILE"

# Add descriptions using a here document for cleaner formatting
cat <<EOF >> "$INFO_FILE"
--- Official Repository Tools ---

[nmap]
Description: Network exploration tool and security/port scanner.
Example: nmap -sV -A target.com

[wireshark-qt]
Description: The world's foremost network protocol analyzer with a graphical interface.
Example: wireshark

[tcpdump]
Description: Powerful command-line packet analyzer.
Example: sudo tcpdump -i eth0 'port 80'

[net-tools]
Description: Basic networking utilities like netstat, arp, and route.
Example: netstat -tulpn

[dnsutils]
Description: Utilities for querying DNS servers, including 'dig' and 'nslookup'.
Example: dig google.com

[openbsd-netcat]
Description: A versatile networking utility for reading/writing data across network connections.
Example: nc -zv target.com 80

[socat]
Description: A multipurpose relay for bidirectional data transfer between two points.
Example: socat TCP-LISTEN:8080,fork TCP:example.com:80

[iptables-nft]
Description: Userspace command line program to configure the Linux kernel firewall.
Example: sudo iptables -L -v -n

[nikto]
Description: A web server scanner which performs comprehensive tests against web servers for multiple items.
Example: nikto -h http://testsite.com

[sqlmap]
Description: An open source penetration testing tool that automates the process of detecting and exploiting SQL injection flaws.
Example: sqlmap -u "http://testsite.com/page.php?id=1"

[gobuster]
Description: A tool used to brute-force URIs (directories and files), DNS subdomains, and virtual host names.
Example: gobuster dir -u http://target.com -w /usr/share/wordlists/dirb/common.txt

[wpscan]
Description: A black box WordPress security scanner.
Example: wpscan --url http://wordpress-site.com

[john]
Description: John the Ripper is a fast password cracker.
Example: john --wordlist=/path/to/pass.lst hash.txt

[hashcat]
Description: The world's fastest and most advanced password recovery utility.
Example: hashcat -m 0 -a 0 hash.txt wordlist.txt

[hydra]
Description: A parallelized login cracker which supports numerous protocols to attack.
Example: hydra -l user -P passlist.txt ftp://target.com

[aircrack-ng]
Description: A complete suite of tools to assess WiFi network security.
Example: sudo airmon-ng start wlan0

[reaver]
Description: Implements a brute force attack against Wi-Fi Protected Setup (WPS) registrar PINs.
Example: sudo reaver -i wlan0mon -b XX:XX:XX:XX:XX:XX -vv

[binwalk]
Description: A tool for searching a given binary image for embedded files and executable code.
Example: binwalk firmware.bin

[ghidra]
Description: A software reverse engineering (SRE) framework created and maintained by the NSA.
Example: ghidraRun

[radare2]
Description: A portable reversing framework.
Example: r2 -d /bin/ls

[gdb]
Description: The GNU Project debugger.
Example: gdb ./my_program

[strace]
Description: A diagnostic, debugging and instructional userspace utility for Linux to trace system calls.
Example: strace ls -l

[ltrace]
Description: A program that simply runs the specified command until it exits, intercepting and recording the dynamic library calls.
Example: ltrace ls -l

[foremost]
Description: A console program to recover files based on their headers, footers, and internal data structures.
Example: foremost -i disk_image.dd -o output/

[htop]
Description: An interactive process viewer for Unix systems.
Example: htop

[fastfetch]
Description: A neofetch-like tool for fetching system information but much faster.
Example: fastfetch

[tmux]
Description: A terminal multiplexer. It lets you switch easily between several programs in one terminal.
Example: tmux new -s session_name

[zsh]
Description: A shell designed for interactive use, although it is also a powerful scripting language.
Example: zsh

[exploitdb]
Description: An archive of public exploits and corresponding vulnerable software, developed for use by penetration testers.
Example: searchsploit apache 2.4


--- AUR (Arch User Repository) Tools ---

[metasploit]
Description: The world's most used penetration testing framework.
Example: msfconsole

[burpsuite]
Description: An integrated platform for performing security testing of web applications.
Example: burpsuite

[dirb]
Description: A web content scanner that looks for existing (and/or hidden) web objects.
Example: dirb http://target.com

[hashcat-utils]
Description: Small utilities that are useful in advanced password cracking.
Example: hcxkeys

[wfuzz]
Description: A tool designed for bruteforcing Web Applications.
Example: wfuzz -c -z file,wordlist.txt http://target.com/FUZZ

[ffuf]
Description: A fast web fuzzer written in Go.
Example: ffuf -w wordlist.txt -u http://target.com/FUZZ

[bloodhound] Not installed because it fails to compile.
Description: Visually displays Active Directory trust relationships in an AD environment.
Example: bloodhound

[impacket]
Description: A collection of Python classes for working with network protocols.
Example: impacket-psexec username@target.com

[volatility3-git]
Description: An open-source memory forensics framework for incident response and malware analysis.
Example: python3 vol.py -f memdump.raw windows.info

EOF

print_message "$GREEN" "Information file created successfully."


# ------------------------------------------------------------------------------
# Finalization
# ------------------------------------------------------------------------------

print_message "$YELLOW" "\n=================================================="
print_message "$GREEN" "  Installation Complete!"
print_message "$YELLOW" "==================================================\n"
print_message "$NC" "All selected tools have been installed on your system."
print_message "$NC" "A list of all installed utilities and their descriptions has been saved to ${GREEN}~/utils-info.txt${NC}"
print_message "$NC" "Some tools, like Metasploit, may require initial database setup."
print_message "$NC" "For Metasploit, run: ${YELLOW}msfdb init${NC}"
print_message "$NC" "Happy hacking (ethically, of course)!\n"

