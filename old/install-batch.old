#!/bin/bash
# bash -c "$(wget -qLO- https://github.com/therepos/proxmox/raw/main/tools/batch-scripts.sh)"
# purpose: this script batches scripts execution

STATE_FILE="/var/tmp/proxmox_setup_state"
TOTAL_STEPS=5

# Function to update state
update_state() {
    echo "$1" >> "$STATE_FILE"
}

# Function to check state
check_state() {
    grep -q "$1" "$STATE_FILE" 2>/dev/null
}

# Ensure state file exists
touch "$STATE_FILE"

# Script 1
if ! check_state "script1"; then
    echo "Running script 1..."
    ./script1.sh
    if [ $? -eq 0 ]; then
        update_state "script1"
        echo "Script 1 completed. Rebooting system."
        reboot
        exit 0
    else
        echo "Script 1 failed. Exiting."
        exit 1
    fi
fi

# Script 2
if ! check_state "script2"; then
    echo "Running script 2..."
    ./script2.sh
    if [ $? -eq 0 ]; then
        update_state "script2"
        echo "Script 2 completed. Rebooting system."
        reboot
        exit 0
    else
        echo "Script 2 failed. Exiting."
        exit 1
    fi
fi

# Script 3
if ! check_state "script3"; then
    echo "Running script 3..."
    ./script3.sh
    if [ $? -eq 0 ]; then
        update_state "script3"
    else
        echo "Script 3 failed. Exiting."
        exit 1
    fi
fi

# Script 4
if ! check_state "script4"; then
    echo "Running script 4..."
    ./script4.sh
    if [ $? -eq 0 ]; then
        update_state "script4"
    else
        echo "Script 4 failed. Exiting."
        exit 1
    fi
fi

# Script 5
if ! check_state "script5"; then
    echo "Running script 5..."
    ./script5.sh
    if [ $? -eq 0 ]; then
        update_state "script5"
    else
        echo "Script 5 failed. Exiting."
        exit 1
    fi
fi

# Final step
echo "All scripts completed successfully!"
exit 0
