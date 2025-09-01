#!/usr/bin/env python3
"""
Azure Blob Storage provider for LND backup system
"""

from typing import List, Tuple, Optional
from datetime import datetime, timezone
from urllib.parse import urlparse
import os
import time

from azure.storage.blob import BlobServiceClient, BlobClient, ContainerClient
from azure.core.exceptions import AzureError, ResourceNotFoundError, ResourceExistsError

from storage_providers import StorageProvider, StorageProviderFactory


class AzureStorageProvider(StorageProvider):
    """Azure Blob Storage provider implementation"""
    
    def __init__(self, config: dict):
        super().__init__(config)
        
        connection_string = config.get('connection_string')
        if not connection_string:
            raise ValueError("connection_string is required for Azure storage provider")
        
        self._parse_connection_string(connection_string)
        self._init_client()
    
    def _parse_connection_string(self, connection_string: str):
        """Parse azure:// connection string format"""
        # Expected format: azure://account.blob.core.windows.net/container?sas_params
        parsed = urlparse(connection_string)
        
        if parsed.scheme != 'azure':
            raise ValueError("Connection string must start with 'azure://'")
        
        if not parsed.hostname or not parsed.hostname.endswith('.blob.core.windows.net'):
            raise ValueError("Invalid Azure Blob Storage hostname in connection string")
        
        self.account_name = parsed.hostname.split('.')[0]
        
        path_parts = parsed.path.strip('/').split('/')
        if not path_parts or not path_parts[0]:
            raise ValueError("Container name not found in connection string")
        
        self.container_name = path_parts[0]
        self.sas_token = parsed.query
        
        # Create the full blob SAS URL for the client
        self.blob_sas_url = f"https://{parsed.hostname}{parsed.path}?{parsed.query}"
        self.account_url = f"https://{parsed.hostname}"

    
    def _init_client(self):
        """Initialize Azure Blob Storage client"""
        try:
            # Use ContainerClient directly with the full SAS URL
            from azure.storage.blob import ContainerClient
            self.container_client = ContainerClient.from_container_url(self.blob_sas_url)
            
            # Don't check if container exists - just assume it does since we have the SAS URL
                
        except Exception as e:
            raise ValueError(f"Failed to initialize Azure client: {e}")
    
    def upload_file(self, file_contents: bytes, remote_path: str) -> bool:
        """Upload file contents to Azure Blob Storage"""
        try:
            blob_client = self.container_client.get_blob_client(remote_path)
            blob_client.upload_blob(file_contents, overwrite=True)
            return True
        except AzureError as e:
            print(f"Azure upload error: {e}")
            return False
        except Exception as e:
            print(f"Upload error: {e}")
            return False
    
    def list_backups(self) -> List[Tuple[str, datetime]]:
        """List backup files with their modification times"""
        try:
            system_dir = self.get_system_backup_dir().lstrip('/')
            blobs = self.container_client.list_blobs(name_starts_with=system_dir)
            
            backup_files = []
            for blob in blobs:
                if blob.name.endswith('.backup'):
                    last_modified = blob.last_modified
                    if last_modified.tzinfo is None:
                        last_modified = last_modified.replace(tzinfo=timezone.utc)
                    backup_files.append((blob.name, last_modified))
            
            return backup_files
        except AzureError as e:
            print(f"Azure list error: {e}")
            return []
        except Exception as e:
            print(f"List error: {e}")
            return []
    
    def delete_file(self, remote_path: str) -> bool:
        """Delete a file from Azure Blob Storage"""
        try:
            blob_client = self.container_client.get_blob_client(remote_path)
            blob_client.delete_blob()
            return True
        except ResourceNotFoundError:
            print(f"File {remote_path} not found for deletion")
            return True
        except AzureError as e:
            print(f"Azure delete error: {e}")
            return False
        except Exception as e:
            print(f"Delete error: {e}")
            return False
    
    def create_directory(self, dir_path: str) -> bool:
        """Create directory in Azure Blob Storage (Azure doesn't have real directories)"""
        return True
    
    def upload_backup_with_retry(self, file_contents: bytes, max_retries: int = 3) -> bool:
        """Upload backup with retry logic and proper error handling"""
        timestamp = datetime.now().strftime('%Y%m%d-%H%M%S')
        
        self.local_backup(file_contents, timestamp)
        
        timestamped_path, latest_path = self.generate_backup_paths(timestamp)
        timestamped_path = timestamped_path.lstrip('/')
        latest_path = latest_path.lstrip('/')
        
        for attempt in range(max_retries):
            try:
                print(f"Uploading backup to {timestamped_path}...")
                if not self.upload_file(file_contents, timestamped_path):
                    raise Exception("Timestamped backup upload failed")
                
                print(f"Updating latest backup at {latest_path}...")
                if not self.upload_file(file_contents, latest_path):
                    raise Exception("Latest backup upload failed")
                
                file_size = len(file_contents)
                print(f"Backup successful: {file_size} bytes at {datetime.now()}")
                
                total_backups = self.cleanup_old_backups()
                print(f"Total backups maintained: {min(total_backups, self.keep_last_n)}")
                
                return True
                
            except Exception as e:
                print(f"Error during backup (attempt {attempt + 1}/{max_retries}): {e}")
                if attempt < max_retries - 1:
                    wait_time = 2 ** attempt
                    print(f"Retrying in {wait_time} seconds...")
                    time.sleep(wait_time)
                else:
                    return False
        
        return False


StorageProviderFactory.register_provider('azure', AzureStorageProvider)