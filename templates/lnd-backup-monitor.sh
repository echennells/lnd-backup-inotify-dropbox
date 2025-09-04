#!/bin/bash
set -euo pipefail

# Load configuration
source "${CONFIG_DIR}/config"

# Read storage connection string from systemd credential or environment
if [[ -z "${STORAGE_CONNECTION_STRING:-}" ]]; then
    if [[ -n "${CREDENTIALS_DIRECTORY:-}" && -f "$CREDENTIALS_DIRECTORY/storage.connection" ]]; then
        STORAGE_CONNECTION_STRING=$(cat "$CREDENTIALS_DIRECTORY/storage.connection")
    else
        echo "ERROR: STORAGE_CONNECTION_STRING environment variable or credential file is required"
        exit 1
    fi
fi

# Export for Python script
export STORAGE_CONNECTION_STRING

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
    
    if python "$(dirname "$0")/backup.py"; then
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

# Track last modification time for fallback checking
LAST_MTIME=0
if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
    LAST_MTIME=$(stat -c %Y "$CHANNEL_BACKUP_PATH" 2>/dev/null || echo 0)
fi

while true; do
    # Wait for file changes or timeout
    # Watch the specific file, not just the directory
    INOTIFY_OUTPUT=""
    if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
        # Watch the existing file
        INOTIFY_OUTPUT=$(timeout "${CHECK_INTERVAL}" inotifywait -e modify,create,close_write,moved_to,moved_from "$CHANNEL_BACKUP_PATH" 2>&1 || true)
    else
        # Watch the directory for file creation
        INOTIFY_OUTPUT=$(timeout "${CHECK_INTERVAL}" inotifywait -e create,moved_to "$(dirname "$CHANNEL_BACKUP_PATH")" 2>&1 | grep "channel.backup" || true)
    fi
    
    FILE_CHANGED=false
    
    # Check if inotify detected a change (filter out "Setting up watches" messages)
    if [[ -n "$INOTIFY_OUTPUT" ]] && [[ "$INOTIFY_OUTPUT" != *"timed out"* ]] && [[ "$INOTIFY_OUTPUT" != *"No such file"* ]] && [[ "$INOTIFY_OUTPUT" != *"Setting up watches"* ]]; then
        echo "[$(date)] inotify detected change: $INOTIFY_OUTPUT"
        FILE_CHANGED=true
    fi
    
    # Fallback: check modification time even if inotify didn't trigger
    if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
        CURRENT_MTIME=$(stat -c %Y "$CHANNEL_BACKUP_PATH" 2>/dev/null || echo 0)
        if [[ "$CURRENT_MTIME" -gt "$LAST_MTIME" ]]; then
            if [[ "$FILE_CHANGED" == false ]]; then
                echo "[$(date)] Fallback detection: file modified (mtime changed from $LAST_MTIME to $CURRENT_MTIME)"
            fi
            FILE_CHANGED=true
            LAST_MTIME=$CURRENT_MTIME
        fi
    fi
    
    if [[ "$FILE_CHANGED" == true ]]; then
        # File changed, wait a moment for write to complete
        sleep 3
        
        if [[ -f "$CHANNEL_BACKUP_PATH" ]]; then
            upload_backup "$CHANNEL_BACKUP_PATH"
            # Update mtime after successful backup
            LAST_MTIME=$(stat -c %Y "$CHANNEL_BACKUP_PATH" 2>/dev/null || echo 0)
        else
            echo "[$(date)] WARNING: File disappeared after change detection"
        fi
    else
        # Timeout reached - this is normal, just continue monitoring
        if [[ "${LOG_LEVEL:-info}" == "debug" ]]; then
            echo "[$(date)] Monitoring timeout - continuing to watch for changes"
        fi
    fi
done