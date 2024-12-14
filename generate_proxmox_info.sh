#!/bin/bash

# Define the output file
OUTPUT_FILE="proxmox_info_$(date +%Y%m%d).txt"

echo "Proxmox Information Collection Script"
echo "-------------------------------------"

# Start collecting data
echo "Collecting Proxmox version information..."
echo "### Proxmox Version Info ###" > $OUTPUT_FILE
pveversion -v >> $OUTPUT_FILE 2>&1

echo "Collecting ZFS status..."
echo -e "\n### ZFS Pool Status ###" >> $OUTPUT_FILE
zpool status >> $OUTPUT_FILE 2>&1

echo -e "\n### ZFS Filesystems ###" >> $OUTPUT_FILE
zfs list >> $OUTPUT_FILE 2>&1

echo "Collecting storage configuration..."
echo -e "\n### Storage Configuration ###" >> $OUTPUT_FILE
cat /etc/pve/storage.cfg >> $OUTPUT_FILE 2>&1

echo "Collecting disk layout and partitions..."
echo -e "\n### Disk Layout ###" >> $OUTPUT_FILE
lsblk -o NAME,SIZE,FSTYPE,MOUNTPOINT >> $OUTPUT_FILE 2>&1

echo -e "\n### Mounted Filesystems ###" >> $OUTPUT_FILE
df -hT >> $OUTPUT_FILE 2>&1

echo "Collecting network configuration..."
echo -e "\n### Network Configuration ###" >> $OUTPUT_FILE
cat /etc/network/interfaces >> $OUTPUT_FILE 2>&1

echo "Collecting CPU information..."
echo -e "\n### CPU Information ###" >> $OUTPUT_FILE
lscpu >> $OUTPUT_FILE 2>&1

echo "Collecting memory status..."
echo -e "\n### Memory Status ###" >> $OUTPUT_FILE
free -h >> $OUTPUT_FILE 2>&1

echo "Collecting VM and LXC container summaries..."
echo -e "\n### VM List ###" >> $OUTPUT_FILE
qm list >> $OUTPUT_FILE 2>&1

echo -e "\n### LXC Container List ###" >> $OUTPUT_FILE
pct list >> $OUTPUT_FILE 2>&1

echo "Collecting complete hardware information..."
echo -e "\n### Complete Hardware Information ###" >> $OUTPUT_FILE
lshw -short >> $OUTPUT_FILE 2>&1

# Compress the output file
echo "Compressing the output file..."
tar -czvf ${OUTPUT_FILE}.tar.gz $OUTPUT_FILE

# Clean up the uncompressed file
rm $OUTPUT_FILE

echo "Information collected and saved to ${OUTPUT_FILE}.tar.gz"
echo "Upload the file to GitHub or share it as needed."
