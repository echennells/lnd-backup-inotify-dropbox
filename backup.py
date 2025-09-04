#!/home/ubuntu/lnd-backup-inotify-dropbox/venv/bin/python3
"""
Modular backup script for LND channel.backup file
Automatically uploads channel backups when changes are detected
"""

import os
from datetime import datetime
import sys
from pathlib import Path
from dotenv import load_dotenv
import socket

from storage_providers import StorageProviderFactory
import azure_provider

load_dotenv()

# Configuration from environment
LOCAL_FILE = os.getenv('LND_CHANNEL_BACKUP_PATH', '/home/ubuntu/volumes/.lnd/data/chain/bitcoin/mainnet/channel.backup')
SYSTEM_ID = os.getenv('SYSTEM_ID', '').strip() or socket.gethostname()

def get_storage_config() -> dict:
    """Get storage provider configuration from environment variables"""
    connection_string = os.getenv('STORAGE_CONNECTION_STRING')

    # Try to read from systemd credential file if env var not set
    if not connection_string:
        credentials_dir = os.getenv('CREDENTIALS_DIRECTORY')
        if credentials_dir:
            storage_connection_file = os.path.join(credentials_dir, 'storage.connection')
            if os.path.exists(storage_connection_file):
                with open(storage_connection_file, 'r') as f:
                    connection_string = f.read().strip()

    if not connection_string:
        raise ValueError("STORAGE_CONNECTION_STRING environment variable or credential file is required")
    
    config = {
        'backup_dir': os.getenv('BACKUP_DIR', '/lightning-backups'),
        'local_backup_dir': os.getenv('LOCAL_BACKUP_DIR', '/var/backup/lnd'),
        'keep_last_n_backups': int(os.getenv('KEEP_LAST_N_BACKUPS', '30')),
        'system_id': SYSTEM_ID,
        'connection_string': connection_string,
    }
    
    return config






def perform_backup(max_retries: int = 3) -> bool:
    """Perform backup using the configured storage provider"""
    backup_file = os.getenv('STAGED_BACKUP_FILE', LOCAL_FILE)
    
    if not os.path.exists(backup_file):
        print(f"Error: {backup_file} not found")
        return False
    
    try:
        config = get_storage_config()
        connection_string = config['connection_string']
        
        # Use explicit provider type if set, otherwise try to parse connection string
        provider_type = os.getenv('STORAGE_PROVIDER', '').strip()
        if provider_type:
            provider = StorageProviderFactory.create_provider(provider_type, config)
        else:
            provider = StorageProviderFactory.create_provider_from_connection_string(connection_string, config)
        
        with open(backup_file, 'rb') as f:
            file_contents = f.read()
        
        if hasattr(provider, 'upload_backup_with_retry'):
            return provider.upload_backup_with_retry(file_contents, max_retries)
        else:
            timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
            provider.local_backup(file_contents, timestamp)
            
            timestamped_path, latest_path = provider.generate_backup_paths(timestamp)
            
            provider.create_directory(provider.get_system_backup_dir())
            
            if not provider.upload_file(file_contents, timestamped_path):
                return False
            
            if not provider.upload_file(file_contents, latest_path):
                return False
            
            file_size = len(file_contents)
            print(f"Backup successful: {file_size} bytes at {datetime.now()}")
            
            total_backups = provider.cleanup_old_backups()
            print(f"Total backups maintained: {min(total_backups, provider.keep_last_n)}")
            
            return True
    
    except Exception as e:
        print(f"Error during backup: {e}")
        return False

def main():
    """Main function"""
    connection_string = os.getenv('STORAGE_CONNECTION_STRING')

    # Try to read from systemd credential file if env var not set
    if not connection_string:
        credentials_dir = os.getenv('CREDENTIALS_DIRECTORY')
        if credentials_dir:
            storage_connection_file = os.path.join(credentials_dir, 'storage.connection')
            if os.path.exists(storage_connection_file):
                with open(storage_connection_file, 'r') as f:
                    connection_string = f.read().strip()

    if connection_string:
        # Check for explicit provider type first
        provider_type = os.getenv('STORAGE_PROVIDER', '').strip()
        if provider_type:
            provider_name = provider_type
        else:
            from urllib.parse import urlparse
            provider_name = urlparse(connection_string).scheme
        print(f"[{datetime.now()}] Starting channel backup using {provider_name} provider...")
    else:
        print(f"[{datetime.now()}] ERROR: STORAGE_CONNECTION_STRING environment variable or credential file is required")
        return 1
    
    backup_file = os.getenv('STAGED_BACKUP_FILE', LOCAL_FILE)
    
    if not Path(backup_file).exists():
        print(f"Warning: Backup file not found at {backup_file}")
        print("This is normal if you haven't opened any channels yet.")
        return 0
    
    success = perform_backup()
    
    if success:
        print(f"[{datetime.now()}] Backup completed successfully")
        return 0
    else:
        print(f"[{datetime.now()}] Backup failed")
        return 1

if __name__ == "__main__":
    sys.exit(main())