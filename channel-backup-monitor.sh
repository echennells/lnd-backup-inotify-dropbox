#!/bin/bash
# LND Channel Backup Monitor
# Uses inotify to watch for changes to channel.backup and triggers Dropbox upload
# Implements checksum verification to ensure file stability before backup

# Load environment variables
export $(grep -v '^#' /home/ubuntu/lnd-backup-inotify-dropbox/.env | xargs)

# Set default if not in env
BACKUP_FILE="${LND_CHANNEL_BACKUP_PATH:-/home/ubuntu/volumes/.lnd/data/chain/bitcoin/signet/channel.backup}"
STAGING_DIR="/tmp/lnd-backup-staging"

# Create staging directory
mkdir -p "$STAGING_DIR"

echo "[$(date)] Starting LND channel backup monitor..."
echo "Monitoring: $BACKUP_FILE"
echo "Staging directory: $STAGING_DIR"

# Check if file exists
if [ ! -f "$BACKUP_FILE" ]; then
    echo "Warning: $BACKUP_FILE does not exist yet."
    echo "This is normal if you haven't opened any channels."
    echo "Waiting for file to be created..."
fi

# Function to verify file stability using checksums
verify_file_stable() {
    local file="$1"
    local max_attempts=3
    local attempt=0
    
    while [ $attempt -lt $max_attempts ]; do
        # Get first checksum
        local hash1=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
        if [ -z "$hash1" ]; then
            echo "[$(date)] Warning: Could not read file for checksum"
            return 1
        fi
        
        # Wait a moment
        sleep 1
        
        # Get second checksum
        local hash2=$(sha256sum "$file" 2>/dev/null | cut -d' ' -f1)
        if [ -z "$hash2" ]; then
            echo "[$(date)] Warning: Could not read file for checksum"
            return 1
        fi
        
        # Compare checksums
        if [ "$hash1" = "$hash2" ]; then
            echo "[$(date)] File is stable (checksum: ${hash1:0:16}...)"
            return 0
        fi
        
        echo "[$(date)] File still changing, waiting... (attempt $((attempt+1))/$max_attempts)"
        sleep 2
        attempt=$((attempt+1))
    done
    
    echo "[$(date)] Warning: File did not stabilize after $max_attempts attempts"
    return 1
}

# Function to perform backup
perform_backup() {
    local timestamp=$(date +%Y%m%d-%H%M%S)
    local staging_file="$STAGING_DIR/channel-$timestamp.backup"
    
    # Copy to staging area
    echo "[$(date)] Copying to staging: $staging_file"
    if cp "$BACKUP_FILE" "$staging_file" 2>/dev/null; then
        # Update environment to point to staged file
        export STAGED_BACKUP_FILE="$staging_file"
        
        # Trigger the backup with staged file
        BACKUP_SCRIPT="/home/ubuntu/lnd-backup-inotify-dropbox/venv/bin/python3 /home/ubuntu/lnd-backup-inotify-dropbox/dropbox_backup.py"
        $BACKUP_SCRIPT
        
        if [ $? -eq 0 ]; then
            echo "[$(date)] Backup completed successfully"
            # Clean up staged file
            rm -f "$staging_file"
        else
            echo "[$(date)] Backup failed! Check logs for details"
            # Keep staged file for debugging
            echo "[$(date)] Staged file kept at: $staging_file"
        fi
    else
        echo "[$(date)] Error: Could not copy file to staging area"
        return 1
    fi
}

# Main monitoring loop
while true; do
    # Wait for file changes (or creation if it doesn't exist)
    if [ -f "$BACKUP_FILE" ]; then
        # File exists, monitor for changes
        # Watch for multiple events that might indicate a write
        inotifywait -e modify,close_write,moved_to,attrib "$BACKUP_FILE"
        echo "[$(date)] Channel backup file event detected"
        
        # Wait a moment for any cascading events
        sleep 2
        
        # Verify file is stable before backing up
        if verify_file_stable "$BACKUP_FILE"; then
            perform_backup
        else
            echo "[$(date)] Skipping backup - file not stable"
        fi
    else
        # File doesn't exist, wait for it to be created
        echo "[$(date)] Waiting for channel.backup to be created..."
        inotifywait -e create,moved_to "$(dirname "$BACKUP_FILE")" 2>/dev/null | grep -q "$(basename "$BACKUP_FILE")"
        
        # File might have been created, check again
        if [ -f "$BACKUP_FILE" ]; then
            echo "[$(date)] Channel backup file created!"
            sleep 2  # Let initial write complete
            if verify_file_stable "$BACKUP_FILE"; then
                perform_backup
            fi
        fi
    fi
done