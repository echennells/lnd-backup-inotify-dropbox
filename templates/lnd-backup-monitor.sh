#!/bin/bash
set -euo pipefail

# Load configuration
source "${CONFIG_DIR}/config"

# Validate storage provider configuration
if [[ -z "${STORAGE_PROVIDER:-}" ]]; then
    export STORAGE_PROVIDER="azure"  # Default to azure
fi

if [[ "$STORAGE_PROVIDER" == "azure" && -z "${AZURE_BLOB_SAS_URL:-}" ]]; then
    echo "ERROR: AZURE_BLOB_SAS_URL environment variable is required for Azure storage provider"
    exit 1
fi

echo "Starting LND Backup Monitor"
echo "Network: $NETWORK"
echo "Storage Provider: $STORAGE_PROVIDER"
echo "Monitoring: $CHANNEL_BACKUP_PATH"

# Function to upload backup
upload_backup() {
    local backup_file="$1"
    
    echo "[$(date)] Starting backup upload for $backup_file"
    
    # Set the staged backup file for the Python script to use
    export STAGED_BACKUP_FILE="$backup_file"
    
    if python3 "$(dirname "$0")/dropbox_backup.py"; then
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