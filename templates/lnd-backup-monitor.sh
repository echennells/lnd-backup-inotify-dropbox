#!/bin/bash
set -euo pipefail

# Load configuration
source "${CONFIG_DIR}/config"

# Load Dropbox token from systemd credentials or file
if [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] && [[ -f "$CREDENTIALS_DIRECTORY/dropbox.token" ]]; then
    export DROPBOX_TOKEN=$(cat "$CREDENTIALS_DIRECTORY/dropbox.token")
elif [[ -n "${DROPBOX_TOKEN_FILE:-}" ]] && [[ -f "$DROPBOX_TOKEN_FILE" ]]; then
    export DROPBOX_TOKEN=$(cat "$DROPBOX_TOKEN_FILE")
elif [[ -z "${DROPBOX_TOKEN:-}" ]]; then
    echo "ERROR: No Dropbox token available"
    exit 1
fi

echo "Starting LND Backup Monitor"
echo "Network: $NETWORK"
echo "Monitoring: $CHANNEL_BACKUP_PATH"
echo "Backup to: $BACKUP_PATH_PREFIX"

# Function to upload backup
upload_backup() {
    local backup_file="$1"
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local remote_path="$BACKUP_PATH_PREFIX/channel-${timestamp}.backup"
    
    echo "[$(date)] Uploading backup to $remote_path"
    
    if python3 "$(dirname "$0")/dropbox_backup.py" "$backup_file" "$remote_path"; then
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