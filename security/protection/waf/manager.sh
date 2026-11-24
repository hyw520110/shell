#!/bin/bash

set -e

# Function to check if python3 is installed
check_python3() {
    if ! command -v python3 &> /dev/null; then
        return 1
    fi
    return 0
}

# Function to install python3 based on Linux distribution
install_python3() {
    local distro=""
    
    # Try to detect Linux distribution
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        distro=$ID
    fi
    
    echo "Python3 is not installed. Attempting to install..."
    
    case $distro in
        "ubuntu"|"debian")
            apt-get update && apt-get install -y python3
            ;;
        "centos"|"rhel"|"fedora")
            yum install -y python3
            ;;
        "alpine")
            apk add --no-cache python3
            ;;
        *)
            echo "Unsupported Linux distribution. Please install Python3 manually using your system's package manager."
            exit 1
            ;;
    esac
    
    # Verify installation
    if ! check_python3; then
        echo "Failed to install Python3. Please install it manually using your system's package manager."
        exit 1
    fi
}

if [[ $EUID -ne 0 ]]; then
  echo "This script must be run as root"
  exit 1
fi

# Check and install Python3 if needed
if ! check_python3; then
    read -p "Python3 is not installed. Would you like to install it automatically? (y/n) " -n 1 -r
    echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        install_python3
    else
        echo "Please install Python3 manually and run this script again."
        exit 1
    fi
fi

URL="https://waf-ce.chaitin.cn/release/latest/manager.py"
FILE_NAME="/tmp/safeline.py"

curl -4sSLk -o "$FILE_NAME" "$URL"

python3 "$FILE_NAME" "$@"
