#!/home/ubuntu/lnd-backup-inotify-dropbox/venv/bin/python3
"""
Taproot Assets daemon backup script
Backs up critical tapd database files that contain asset ownership data
WARNING: Loss of these files means permanent loss of all Taproot Assets
"""

import dropbox
from dropbox.files import WriteMode
import os
import tarfile
import tempfile
from datetime import datetime
import sys
from pathlib import Path
from dotenv import load_dotenv
import time
import hashlib

# Load environment variables
load_dotenv()

def load_dropbox_token():
    """Load Dropbox token from systemd credential or environment variable"""
    # Try systemd credential first (preferred for production)
    credentials_dir = os.getenv('CREDENTIALS_DIRECTORY')
    if credentials_dir:
        token_file = os.path.join(credentials_dir, 'dropbox-token')
        try:
            with open(token_file, 'r') as f:
                token = f.read().strip()
                if token and token != 'YOUR_TOKEN_HERE_REPLACE_ME':
                    return token
        except (FileNotFoundError, PermissionError):
            pass
    
    # Fallback to environment variable (development/legacy)
    token = os.getenv('DROPBOX_ACCESS_TOKEN')
    if token and token != 'YOUR_TOKEN_HERE_REPLACE_ME':
        return token
    
    return None

# Configuration from environment
DROPBOX_ACCESS_TOKEN = load_dropbox_token()
TAPD_DATA_DIR = os.getenv('TAPD_DATA_DIR', '/home/ubuntu/volumes/.tapd/data/mainnet')
DROPBOX_DIR = os.getenv('DROPBOX_BACKUP_DIR', '/lightning-backups')
LOCAL_BACKUP_DIR = os.getenv('LOCAL_BACKUP_DIR', '/home/ubuntu/lnd-backups')
KEEP_LAST_N = int(os.getenv('KEEP_LAST_N_BACKUPS', '30'))

# System identifier for multi-node setups
import socket
SYSTEM_ID = os.getenv('SYSTEM_ID', '').strip() or socket.gethostname()

def setup_dropbox_client():
    """Initialize and verify Dropbox client"""
    if not DROPBOX_ACCESS_TOKEN:
        print("Error: DROPBOX_ACCESS_TOKEN not configured")
        print("Please configure via systemd credential or .env file")
        print("For systemd: store token in credential 'dropbox-token'")
        print("For development: add DROPBOX_ACCESS_TOKEN to .env file")
        return None
    
    try:
        dbx = dropbox.Dropbox(DROPBOX_ACCESS_TOKEN)
        dbx.users_get_current_account()
        return dbx
    except dropbox.exceptions.AuthError:
        print("Error: Invalid Dropbox access token")
        return None
    except Exception as e:
        print(f"Error connecting to Dropbox: {e}")
        return None

def get_tapd_files():
    """Get list of tapd database files to backup
    
    According to Lightning Labs documentation:
    - tapd.db, tapd.db-wal, and tapd.db-shm are critical
    - Loss of these files means permanent loss of all Taproot Assets
    - The proofs directory is optional but recommended
    """
    files_to_backup = []
    tapd_dir = Path(TAPD_DATA_DIR)
    
    if not tapd_dir.exists():
        print(f"Warning: Tapd directory not found at {TAPD_DATA_DIR}")
        return files_to_backup, []
    
    # Critical database files (MUST be backed up)
    db_file = tapd_dir / "tapd.db"
    if db_file.exists():
        files_to_backup.append(db_file)
    
    # WAL (Write-Ahead Logging) file - critical for data consistency
    wal_file = tapd_dir / "tapd.db-wal"
    if wal_file.exists():
        files_to_backup.append(wal_file)
    
    # Shared memory file - needed for SQLite consistency
    shm_file = tapd_dir / "tapd.db-shm"
    if shm_file.exists():
        files_to_backup.append(shm_file)
    
    # Proof files (optional but recommended for faster access)
    proof_files = []
    proofs_dir = tapd_dir / "proofs"
    if proofs_dir.exists() and proofs_dir.is_dir():
        # Get all proof files recursively
        proof_files = list(proofs_dir.rglob("*"))
        if proof_files:
            print(f"Found {len(proof_files)} proof files to include in backup")
    
    if not files_to_backup:
        print("WARNING: No tapd database files found - this is CRITICAL!")
        print("Without these files, all Taproot Assets will be permanently lost!")
    
    return files_to_backup, proof_files

def calculate_checksum(file_path):
    """Calculate SHA256 checksum of a file"""
    sha256 = hashlib.sha256()
    with open(file_path, 'rb') as f:
        for chunk in iter(lambda: f.read(4096), b""):
            sha256.update(chunk)
    return sha256.hexdigest()

def create_backup_archive(timestamp):
    """Create tar.gz archive of tapd database files and optional proof files"""
    db_files, proof_files = get_tapd_files()
    
    if not db_files:
        return None, {}
    
    # Create temporary archive file
    archive_path = Path(tempfile.gettempdir()) / f"tapd-backup-{timestamp}.tar.gz"
    
    checksums = {}
    with tarfile.open(archive_path, "w:gz") as tar:
        # Add critical database files
        for file_path in db_files:
            if file_path.is_file():
                # Calculate checksum before adding to archive
                checksums[file_path.name] = calculate_checksum(file_path)
                
                # Add file to archive with relative path
                arcname = f"tapd-backup-{timestamp}/database/{file_path.name}"
                tar.add(file_path, arcname=arcname)
                print(f"Added {file_path.name} to archive (checksum: {checksums[file_path.name][:16]}...)")
        
        # Add proof files if they exist (optional but recommended)
        if proof_files:
            tapd_dir = Path(TAPD_DATA_DIR)
            for proof_file in proof_files:
                if proof_file.is_file():
                    # Calculate relative path from tapd directory
                    rel_path = proof_file.relative_to(tapd_dir)
                    arcname = f"tapd-backup-{timestamp}/{rel_path}"
                    tar.add(proof_file, arcname=arcname)
            print(f"Added {len(proof_files)} proof files to archive")
    
    return archive_path, checksums

def cleanup_old_backups(dbx, prefix="tapd-backup-"):
    """Remove old tapd backups from Dropbox"""
    try:
        result = dbx.files_list_folder(f"{DROPBOX_DIR}/{SYSTEM_ID}")
        
        # Filter for tapd backup files
        backups = [
            entry for entry in result.entries 
            if entry.name.startswith(prefix) and entry.name.endswith('.tar.gz')
        ]
        
        # Sort by modification time (newest first)
        backups.sort(key=lambda x: x.server_modified, reverse=True)
        
        # Delete old backups
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

def local_backup(archive_path, timestamp):
    """Create local backup copy of the archive"""
    try:
        Path(LOCAL_BACKUP_DIR).mkdir(parents=True, exist_ok=True)
        
        # Create tapd subdirectory
        tapd_backup_dir = Path(LOCAL_BACKUP_DIR) / "tapd"
        tapd_backup_dir.mkdir(exist_ok=True)
        
        # Copy archive to local backup directory
        local_file = tapd_backup_dir / f"tapd-backup-{timestamp}.tar.gz"
        with open(archive_path, 'rb') as src, open(local_file, 'wb') as dst:
            dst.write(src.read())
        
        # Also maintain a 'latest' copy locally
        latest_file = tapd_backup_dir / "tapd-latest.tar.gz"
        with open(archive_path, 'rb') as src, open(latest_file, 'wb') as dst:
            dst.write(src.read())
        
        print(f"Local backup saved: {local_file}")
        
        # Cleanup old local backups
        backups = sorted(tapd_backup_dir.glob("tapd-backup-*.tar.gz"))
        if len(backups) > KEEP_LAST_N:
            for old_backup in backups[:-KEEP_LAST_N]:
                old_backup.unlink()
                print(f"Removed old local backup: {old_backup.name}")
        
        return True
    except Exception as e:
        print(f"Warning: Local backup failed: {e}")
        return False

def upload_to_dropbox(archive_path, timestamp, checksums, max_retries=3):
    """Upload tapd backup archive to Dropbox with retry logic"""
    
    dbx = setup_dropbox_client()
    if not dbx:
        return False
    
    # Read archive file
    with open(archive_path, 'rb') as f:
        archive_contents = f.read()
    
    # First, create local backup (always do this, even if Dropbox fails)
    local_backup(archive_path, timestamp)
    
    for attempt in range(max_retries):
        try:
            # Generate Dropbox paths with system identifier
            system_dir = f"{DROPBOX_DIR}/{SYSTEM_ID}"
            timestamped_path = f"{system_dir}/tapd-backup-{timestamp}.tar.gz"
            latest_path = f"{system_dir}/tapd-latest.tar.gz"
            checksum_path = f"{system_dir}/tapd-backup-{timestamp}.checksums"
            
            # Create backup directories if they don't exist
            try:
                dbx.files_get_metadata(DROPBOX_DIR)
            except:
                dbx.files_create_folder_v2(DROPBOX_DIR)
                print(f"Created Dropbox folder: {DROPBOX_DIR}")
            
            try:
                dbx.files_get_metadata(system_dir)
            except:
                dbx.files_create_folder_v2(system_dir)
                print(f"Created system folder: {system_dir}")
            
            # Upload timestamped backup
            print(f"Uploading backup to {timestamped_path}...")
            dbx.files_upload(
                archive_contents,
                timestamped_path,
                mode=WriteMode('overwrite'),
                autorename=True
            )
            
            # Upload checksums file
            checksum_content = "\n".join([f"{fname}: {checksum}" for fname, checksum in checksums.items()])
            dbx.files_upload(
                checksum_content.encode(),
                checksum_path,
                mode=WriteMode('overwrite')
            )
            
            # Also upload as latest version
            print(f"Updating latest backup at {latest_path}...")
            dbx.files_upload(
                archive_contents,
                latest_path,
                mode=WriteMode('overwrite')
            )
            
            # Get file size for logging
            file_size = len(archive_contents)
            print(f"Backup successful: {file_size} bytes at {datetime.now()}")
            
            # Cleanup old backups
            total_backups = cleanup_old_backups(dbx)
            print(f"Total tapd backups maintained: {min(total_backups, KEEP_LAST_N)}")
            
            return True
            
        except dropbox.exceptions.ApiError as e:
            if e.error.is_path() and e.error.get_path().is_insufficient_space():
                print("Error: Insufficient space in Dropbox")
                return False
            else:
                print(f"Dropbox API error (attempt {attempt + 1}/{max_retries}): {e}")
                if attempt < max_retries - 1:
                    wait_time = 2 ** attempt
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
    
    return False

def main():
    """Main function"""
    print(f"[{datetime.now()}] Starting Taproot Assets backup...")
    print("="*70)
    print("CRITICAL WARNING: Per Lightning Labs v0.3.0+ documentation:")
    print("- tapd database files MUST be backed up regularly (hourly or more)")
    print("- Loss of these files = PERMANENT loss of ALL Taproot Assets")
    print("- The BTC anchoring the assets will also be unspendable")
    print("- Recovery from lnd seed alone is NOT possible")
    print("="*70)
    
    # Check if tapd directory exists
    if not Path(TAPD_DATA_DIR).exists():
        print(f"Tapd directory not found at {TAPD_DATA_DIR}")
        print("If you're not running tapd, you can disable these backups by setting TAPD_ENABLED=false")
        return 0
    
    # Generate timestamp
    timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
    
    # Create backup archive
    print("Creating backup archive...")
    archive_path, checksums = create_backup_archive(timestamp)
    
    if not archive_path:
        print("No tapd files to backup")
        return 1
    
    try:
        # Upload to Dropbox
        success = upload_to_dropbox(archive_path, timestamp, checksums)
        
        # Clean up temporary archive
        if archive_path.exists():
            archive_path.unlink()
        
        if success:
            print(f"[{datetime.now()}] Tapd backup completed successfully")
            return 0
        else:
            print(f"[{datetime.now()}] Tapd backup failed")
            return 1
            
    except Exception as e:
        print(f"Error: {e}")
        # Clean up temporary archive on error
        if archive_path and archive_path.exists():
            archive_path.unlink()
        return 1

if __name__ == "__main__":
    sys.exit(main())