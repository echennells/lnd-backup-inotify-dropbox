#!/bin/bash
# Taproot Assets Database Real-time Backup Monitor
# Uses inotify to detect changes to tapd database files and triggers immediate backup
# CRITICAL: Loss of these files means permanent loss of all Taproot Assets

set -euo pipefail

# Load configuration
CONFIG_DIR="${CONFIG_DIR:-/etc/lnd-backup}"
if [ -f "${CONFIG_DIR}/config" ]; then
    source "${CONFIG_DIR}/config"
fi

# Default configuration
TAPD_DATA_DIR="${TAPD_DATA_DIR:-/home/ubuntu/volumes/.tapd/data/mainnet}"
STAGING_DIR="${STAGING_DIR:-/tmp/tapd-backup-staging}"
CHECK_INTERVAL="${CHECK_INTERVAL:-300}"
LOG_LEVEL="${LOG_LEVEL:-info}"
BACKUP_SCRIPT="${BACKUP_SCRIPT:-/home/ubuntu/lnd-backup-inotify-dropbox/venv/bin/python3 /home/ubuntu/lnd-backup-inotify-dropbox/tapd_backup.py}"

# Ensure staging directory exists
mkdir -p "$STAGING_DIR"

# Critical database files to monitor
DB_FILE="${TAPD_DATA_DIR}/tapd.db"
WAL_FILE="${TAPD_DATA_DIR}/tapd.db-wal"
SHM_FILE="${TAPD_DATA_DIR}/tapd.db-shm"

# Track last backup time to prevent backup storms
LAST_BACKUP_FILE="${STAGING_DIR}/.last_tapd_backup"
MIN_BACKUP_INTERVAL=10  # Minimum seconds between backups

log_message() {
    local level="$1"
    shift
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$level] $*"
}

should_backup() {
    # Check if enough time has passed since last backup
    if [ -f "$LAST_BACKUP_FILE" ]; then
        local last_backup=$(cat "$LAST_BACKUP_FILE")
        local current_time=$(date +%s)
        local time_diff=$((current_time - last_backup))
        
        if [ $time_diff -lt $MIN_BACKUP_INTERVAL ]; then
            log_message "DEBUG" "Skipping backup - only ${time_diff}s since last backup (min: ${MIN_BACKUP_INTERVAL}s)"
            return 1
        fi
    fi
    return 0
}

perform_backup() {
    local reason="$1"
    
    if ! should_backup; then
        return 0
    fi
    
    log_message "INFO" "Triggering tapd backup: $reason"
    
    # Update last backup timestamp
    date +%s > "$LAST_BACKUP_FILE"
    
    # Execute backup script
    if $BACKUP_SCRIPT; then
        log_message "INFO" "Tapd backup completed successfully"
    else
        log_message "ERROR" "Tapd backup failed with exit code $?"
    fi
}

check_db_exists() {
    if [ ! -f "$DB_FILE" ]; then
        log_message "WARN" "Tapd database not found at $DB_FILE"
        log_message "WARN" "Waiting for tapd to create database..."
        return 1
    fi
    return 0
}

monitor_with_inotify() {
    log_message "INFO" "Starting inotify monitor for tapd database files"
    
    # Monitor the tapd data directory for changes to database files
    inotifywait -m -e modify,close_write,moved_to \
        --format '%w%f %e' \
        "$TAPD_DATA_DIR" 2>/dev/null | \
    while read file events; do
        # Check if the modified file is one of our database files
        case "$file" in
            "$DB_FILE"|"$WAL_FILE"|"$SHM_FILE")
                log_message "DEBUG" "Detected change to $(basename "$file"): $events"
                
                # For SQLite, meaningful changes typically happen on close_write
                if [[ "$events" == *"CLOSE_WRITE"* ]] || [[ "$events" == *"MOVED_TO"* ]]; then
                    perform_backup "Database file $(basename "$file") modified"
                fi
                ;;
        esac
    done
}

fallback_check() {
    # Fallback monitoring using file modification times
    local last_db_mtime=""
    local last_wal_mtime=""
    
    while true; do
        if check_db_exists; then
            # Get current modification times
            local current_db_mtime=$(stat -c %Y "$DB_FILE" 2>/dev/null || echo "0")
            local current_wal_mtime=$(stat -c %Y "$WAL_FILE" 2>/dev/null || echo "0")
            
            # Check if files have been modified
            if [ "$last_db_mtime" != "" ]; then
                if [ "$current_db_mtime" != "$last_db_mtime" ] || \
                   [ "$current_wal_mtime" != "$last_wal_mtime" ]; then
                    perform_backup "Database files modified (detected by fallback check)"
                fi
            else
                # First run - perform initial backup
                perform_backup "Initial backup on monitor start"
            fi
            
            # Update last known modification times
            last_db_mtime="$current_db_mtime"
            last_wal_mtime="$current_wal_mtime"
        fi
        
        sleep "$CHECK_INTERVAL"
    done
}

cleanup() {
    log_message "INFO" "Shutting down tapd backup monitor..."
    exit 0
}

# Set up signal handlers
trap cleanup SIGINT SIGTERM

# Main execution
main() {
    log_message "INFO" "========================================"
    log_message "INFO" "Taproot Assets Backup Monitor Starting"
    log_message "INFO" "========================================"
    log_message "WARN" "CRITICAL: tapd database backups are essential!"
    log_message "WARN" "Loss of these files = permanent loss of ALL assets"
    log_message "INFO" "Monitoring: $TAPD_DATA_DIR"
    log_message "INFO" "Check interval: ${CHECK_INTERVAL}s"
    
    # Wait for database to exist
    while ! check_db_exists; do
        sleep 10
    done
    
    # Try to use inotify if available
    if command -v inotifywait &> /dev/null; then
        log_message "INFO" "Using inotify for real-time monitoring"
        
        # Run inotify in background
        monitor_with_inotify &
        INOTIFY_PID=$!
        
        # Also run fallback check in case inotify fails
        fallback_check &
        FALLBACK_PID=$!
        
        # Wait for either process to exit
        wait $INOTIFY_PID $FALLBACK_PID
    else
        log_message "WARN" "inotify-tools not installed, using fallback polling"
        fallback_check
    fi
}

main "$@"