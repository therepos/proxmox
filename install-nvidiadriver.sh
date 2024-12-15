#!/usr/bin/env bash

# wget --no-cache -qO- https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash
# curl -fsSL https://raw.githubusercontent.com/therepos/proxmox/main/install-nvidiadriver.sh | bash

# Blacklist nouveau driver
echo "blacklist nouveau" | sudo tee /etc/modprobe.d/blacklist-nouveau.conf
echo "options nouveau modeset=0" | sudo tee -a /etc/modprobe.d/blacklist-nouveau.conf
sudo update-initramfs -u

# Install dependencies
sudo apt install -y build-essential pve-headers-$(uname -r) pkg-config libglvnd-dev libx11-dev libxext-dev xorg-dev xserver-xorg-core xserver-xorg-dev lib32z1

# Ensure the PKG_CONFIG_PATH configuration is not duplicated in ~/.bashrc
if ! grep -q '^export PKG_CONFIG_PATH=\$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' ~/.bashrc; then
    echo 'export PKG_CONFIG_PATH=$PKG_CONFIG_PATH:/usr/lib/x86_64-linux-gnu/pkgconfig/' >> ~/.bashrc
    echo "Added PKG_CONFIG_PATH configuration to ~/.bashrc"
else
    echo "PKG_CONFIG_PATH configuration already exists in ~/.bashrc"
fi

# Download NVIDIA driver installer to a temporary file and execute
wget -qO /tmp/NVIDIA-Linux-x86_64-550.135.run https://us.download.nvidia.com/XFree86/Linux-x86_64/550.135/NVIDIA-Linux-x86_64-550.135.run

# Run the installer directly
bash /tmp/NVIDIA-Linux-x86_64-550.135.run --accept-license --install-compat32-libs --glvnd-egl-config-path=/etc/glvnd/egl_vendor.d --dkms --update-xconfig --silent

# Clean up the temporary file
rm -f /tmp/NVIDIA-Linux-x86_64-550.135.run

# Update and install CUDA keyring
sudo apt update
sudo apt install -y cuda-keyring

: <<'EOF'
#The -y flag skips confirmation for autoremove.
sudo ./NVIDIA-Linux-x86_64-550.135.run --uninstall
apt-get remove --purge '^nvidia-.*'
apt-get autoremove -y 

#
sudo apt install nvidia-driver

#
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/libnvidia-container1_1.17.3-1_amd64.deb
wget https://developer.download.nvidia.com/compute/cuda/repos/debian12/x86_64/nvidia-container-toolkit_1.17.3-1_amd64.deb
sudo dpkg -i libnvidia-container1_1.17.3-1_amd64.deb
sudo dpkg -i nvidia-container-toolkit_1.17.3-1_amd64.deb

# Verify NVIDIA driver version:
nvidia-smi

# Verify the DKMS module:
dkms status

# Ensure the X configuration file is updated:
cat /etc/X11/xorg.conf

# Find
sudo find / -name nvidia-uninstall 2>/dev/null


EOF

