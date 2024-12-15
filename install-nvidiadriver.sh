#!/usr/bin/env bash

# Blacklist nouveau driver
echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" | sudo tee -a /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u

# Install dependencies
sudo apt install -y build-essential pve-headers-$(uname -r) pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1

# Append to end of file
echo 'export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' >> ~/.bashrc

# Download NVIDIA driver
wget https://us.download.nvidia.com/XFree86/Linux-x86_64/550.135/NVIDIA-Linux-x86_64-550.135.run

# Make the driver script executable
chmod +x NVIDIA-Linux-x86_64-550.135.run

# Run the driver installation script
sudo ./NVIDIA-Linux-x86_64-550.135.run --glvnd-egl-config-path=/etc/glvnd/egl_vendor.d
# sudo ./NVIDIA-Linux-x86_64-550.135.run -a -s -N --no-drm --log-file=/tmp/nvidia-installer.log

# Update and install CUDA keyring
sudo apt update
sudo apt install -y cuda-keyring

# Verify 
nvidia-smi

: <<'EOF'
#The -y flag skips confirmation for autoremove.
apt-get remove --purge '^nvidia-.*'
apt-get autoremove -y 

#
sudo apt install nvidia-driver

#
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/libnvidia-container1_1.17.3-1_amd64.deb
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/nvidia-container-toolkit_1.17.3-1_amd64.deb
sudo dpkg -i libnvidia-container1_1.17.3-1_amd64.deb
sudo dpkg -i nvidia-container-toolkit_1.17.3-1_amd64.deb

#
sudo ./NVIDIA-Linux-x86_64-550.135.run --uninstall

EOF

