#!/bin/bash
set -euo pipefail

# Load configuration
source "${CONFIG_DIR}/config"

# Validate storage connection string
if [[ -z "${STORAGE_CONNECTION_STRING:-}" ]]; then
    echo "ERROR: STORAGE_CONNECTION_STRING environment variable is required"
    exit 1
fi

# Extract provider from connection string for logging
PROVIDER=$(echo "$STORAGE_CONNECTION_STRING" | cut -d':' -f1)

echo "Starting LND Backup Monitor"
echo "Network: $NETWORK"
echo "Storage Provider: $PROVIDER"
echo "Monitoring: $CHANNEL_BACKUP_PATH"

# Function to upload backup
upload_backup() {
    local backup_file="$1"
    
    echo "[$(date)] Starting backup upload for $backup_file"
    
    # Set the staged backup file for the Python script to use
    export STAGED_BACKUP_FILE="$backup_file"
    
    if python3 "$(dirname "$0")/backup.py"; then
        echo "[$(date)] Backup uploaded successfully"
    else
        echo "[$(date)] ERROR: Backup upload failed"
        return 1
    fi
}

# Initial upload if file exists
if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
    upload_backup "$CHANNEL_BACKUP_PATH"
else
    echo "WARNING: Channel backup file not found at $CHANNEL_BACKUP_PATH"
    echo "Will wait for it to be created..."
fi

# Monitor for changes
echo "Monitoring for changes..."
while true; do
    # Wait for file changes or timeout
    if inotifywait -e modify,create,close_write -t "${CHECK_INTERVAL}" \
        "$(dirname "$CHANNEL_BACKUP_PATH")" 2>/dev/null | grep -q "channel.backup"; then
        
        # File changed, wait a moment for write to complete
        sleep 2
        
        if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
            upload_backup "$CHANNEL_BACKUP_PATH"
        fi
    else
        # Timeout reached, do periodic backup if file exists
        if [[ -f "$CHANNEL_BACKUP_PATH" ]] && [[ "${LOG_LEVEL:-info}" == "debug" ]]; then
            echo "[$(date)] Periodic check - file unchanged"
        fi
    fi
done