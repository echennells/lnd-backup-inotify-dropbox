#!/home/ubuntu/lnd-backup-inotify-dropbox/venv/bin/python3
"""
Dropbox backup script for LND channel.backup file
Automatically uploads channel backups when changes are detected
"""

import dropbox
from dropbox.files import WriteMode
import os
from datetime import datetime
import sys
from pathlib import Path
from dotenv import load_dotenv
import time

# Load environment variables
load_dotenv()

# Configuration from environment
DROPBOX_ACCESS_TOKEN = os.getenv('DROPBOX_ACCESS_TOKEN')
LOCAL_FILE = os.getenv('LND_CHANNEL_BACKUP_PATH', '/home/ubuntu/volumes/.lnd/data/chain/bitcoin/mainnet/channel.backup')
DROPBOX_DIR = os.getenv('DROPBOX_BACKUP_DIR', '/lightning-backups')
KEEP_LAST_N = int(os.getenv('KEEP_LAST_N_BACKUPS', '30'))

def setup_dropbox_client():
    """Initialize and verify Dropbox client"""
    if not DROPBOX_ACCESS_TOKEN or DROPBOX_ACCESS_TOKEN == 'YOUR_TOKEN_HERE_REPLACE_ME':
        print("Error: DROPBOX_ACCESS_TOKEN not configured in .env file")
        print("Please add your Dropbox access token to the .env file")
        return None
    
    try:
        dbx = dropbox.Dropbox(DROPBOX_ACCESS_TOKEN)
        # Test authentication
        dbx.users_get_current_account()
        return dbx
    except dropbox.exceptions.AuthError:
        print("Error: Invalid Dropbox access token")
        print("Please check DROPBOX_ACCESS_TOKEN in .env file")
        return None
    except Exception as e:
        print(f"Error connecting to Dropbox: {e}")
        return None

def cleanup_old_backups(dbx):
    """Remove old backups, keeping only the last N backups"""
    try:
        # List all files in backup directory
        result = dbx.files_list_folder(DROPBOX_DIR)
        
        # Filter for backup files (exclude the 'latest' file)
        backups = [
            entry for entry in result.entries 
            if entry.name.startswith('channel-backup-') and entry.name.endswith('.backup')
        ]
        
        # Sort by modification time (newest first)
        backups.sort(key=lambda x: x.server_modified, reverse=True)
        
        # Delete old backups if we have more than KEEP_LAST_N
        if len(backups) > KEEP_LAST_N:
            for backup in backups[KEEP_LAST_N:]:
                try:
                    dbx.files_delete_v2(backup.path_lower)
                    print(f"Deleted old backup: {backup.name}")
                except Exception as e:
                    print(f"Warning: Could not delete {backup.name}: {e}")
        
        return len(backups)
    
    except Exception as e:
        print(f"Warning: Could not cleanup old backups: {e}")
        return 0

def upload_to_dropbox(max_retries=3):
    """Upload channel.backup to Dropbox with retry logic"""
    
    # Check if we're using a staged file (safer) or direct file
    backup_file = os.getenv('STAGED_BACKUP_FILE', LOCAL_FILE)
    
    # Check if backup file exists
    if not os.path.exists(backup_file):
        print(f"Error: {backup_file} not found")
        return False
    
    # Setup Dropbox client
    dbx = setup_dropbox_client()
    if not dbx:
        return False
    
    # Retry logic for network failures
    for attempt in range(max_retries):
        try:
            # Read the backup file  
            with open(backup_file, 'rb') as f:
                file_contents = f.read()
            
            # Generate filenames
            timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
            timestamped_path = f"{DROPBOX_DIR}/channel-backup-{timestamp}.backup"
            latest_path = f"{DROPBOX_DIR}/channel-latest.backup"
            
            # Create backup directory if it doesn't exist
            try:
                dbx.files_get_metadata(DROPBOX_DIR)
            except:
                dbx.files_create_folder_v2(DROPBOX_DIR)
                print(f"Created Dropbox folder: {DROPBOX_DIR}")
            
            # Upload timestamped backup
            print(f"Uploading backup to {timestamped_path}...")
            dbx.files_upload(
                file_contents,
                timestamped_path,
                mode=WriteMode('overwrite'),
                autorename=True
            )
            
            # Also upload as latest version
            print(f"Updating latest backup at {latest_path}...")
            dbx.files_upload(
                file_contents,
                latest_path,
                mode=WriteMode('overwrite')
            )
            
            # Get file size for logging
            file_size = len(file_contents)
            print(f"✓ Backup successful: {file_size} bytes at {datetime.now()}")
            
            # Cleanup old backups
            total_backups = cleanup_old_backups(dbx)
            print(f"Total backups maintained: {min(total_backups, KEEP_LAST_N)}")
            
            return True
            
        except dropbox.exceptions.ApiError as e:
            if e.error.is_path() and e.error.get_path().is_insufficient_space():
                print("Error: Insufficient space in Dropbox")
                return False  # Don't retry on space issues
            else:
                print(f"Dropbox API error (attempt {attempt + 1}/{max_retries}): {e}")
                if attempt < max_retries - 1:
                    wait_time = 2 ** attempt  # Exponential backoff: 1s, 2s, 4s
                    print(f"Retrying in {wait_time} seconds...")
                    time.sleep(wait_time)
                else:
                    return False
        except Exception as e:
            print(f"Error during backup (attempt {attempt + 1}/{max_retries}): {e}")
            if attempt < max_retries - 1:
                wait_time = 2 ** attempt
                print(f"Retrying in {wait_time} seconds...")
                time.sleep(wait_time)
            else:
                return False
    
    return False  # Should not reach here

def main():
    """Main function"""
    print(f"[{datetime.now()}] Starting channel backup to Dropbox...")
    
    # Check which file we're backing up
    backup_file = os.getenv('STAGED_BACKUP_FILE', LOCAL_FILE)
    
    # Verify configuration
    if not Path(backup_file).exists():
        print(f"Warning: Backup file not found at {backup_file}")
        print("This is normal if you haven't opened any channels yet.")
        return 0
    
    # Perform backup
    success = upload_to_dropbox()
    
    if success:
        print(f"[{datetime.now()}] Backup completed successfully")
        return 0
    else:
        print(f"[{datetime.now()}] Backup failed")
        return 1

if __name__ == "__main__":
    sys.exit(main())