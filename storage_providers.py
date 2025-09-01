#!/usr/bin/env python3
"""
Modular storage provider interface for LND backup system
Supports different cloud storage providers with a common interface
"""

from abc import ABC, abstractmethod
from typing import List, Tuple, Optional
from datetime import datetime
from pathlib import Path
import os
from urllib.parse import urlparse, parse_qs


class StorageProvider(ABC):
    """Abstract base class for storage providers"""
    
    def __init__(self, config: dict):
        self.config = config
        self.backup_dir = config.get('backup_dir', '/lightning-backups')
        self.local_backup_dir = config.get('local_backup_dir', '/var/backup/lnd')
        self.keep_last_n = int(config.get('keep_last_n_backups', 30))
        self.system_id = config.get('system_id', 'default')
    
    @abstractmethod
    def upload_file(self, file_contents: bytes, remote_path: str) -> bool:
        """Upload file contents to remote storage"""
        pass
    
    @abstractmethod
    def list_backups(self) -> List[Tuple[str, datetime]]:
        """List backup files with their modification times"""
        pass
    
    @abstractmethod
    def delete_file(self, remote_path: str) -> bool:
        """Delete a file from remote storage"""
        pass
    
    @abstractmethod
    def create_directory(self, dir_path: str) -> bool:
        """Create directory in remote storage"""
        pass
    
    def get_system_backup_dir(self) -> str:
        """Get system-specific backup directory path"""
        return f"{self.backup_dir}/{self.system_id}"
    
    def generate_backup_paths(self, timestamp: str) -> Tuple[str, str]:
        """Generate timestamped and latest backup paths"""
        system_dir = self.get_system_backup_dir()
        timestamped_path = f"{system_dir}/channel-backup-{timestamp}.backup"
        latest_path = f"{system_dir}/channel-latest.backup"
        return timestamped_path, latest_path
    
    def local_backup(self, file_contents: bytes, timestamp: str) -> bool:
        """Create local backup copy"""
        try:
            Path(self.local_backup_dir).mkdir(parents=True, exist_ok=True)
            
            local_file = Path(self.local_backup_dir) / f"channel-backup-{timestamp}.backup"
            local_file.write_bytes(file_contents)
            
            latest_file = Path(self.local_backup_dir) / "channel-latest.backup"
            latest_file.write_bytes(file_contents)
            
            print(f"Local backup saved: {local_file}")
            
            self._cleanup_local_backups()
            return True
        except Exception as e:
            print(f"Warning: Local backup failed: {e}")
            return False
    
    def _cleanup_local_backups(self):
        """Remove old local backups"""
        try:
            backups = sorted(Path(self.local_backup_dir).glob("channel-backup-*.backup"))
            if len(backups) > self.keep_last_n:
                for old_backup in backups[:-self.keep_last_n]:
                    old_backup.unlink()
                    print(f"Removed old local backup: {old_backup.name}")
        except Exception as e:
            print(f"Warning: Local backup cleanup failed: {e}")
    
    def cleanup_old_backups(self) -> int:
        """Remove old backups, keeping only the last N backups"""
        try:
            backups = self.list_backups()
            backup_files = [
                (path, mod_time) for path, mod_time in backups 
                if '/channel-backup-' in path and path.endswith('.backup')
            ]
            
            backup_files.sort(key=lambda x: x[1], reverse=True)
            
            if len(backup_files) > self.keep_last_n:
                for backup_path, _ in backup_files[self.keep_last_n:]:
                    try:
                        if self.delete_file(backup_path):
                            print(f"Deleted old backup: {Path(backup_path).name}")
                    except Exception as e:
                        print(f"Warning: Could not delete {backup_path}: {e}")
            
            return len(backup_files)
        
        except Exception as e:
            print(f"Warning: Could not cleanup old backups: {e}")
            return 0


class StorageProviderFactory:
    """Factory class for creating storage provider instances"""
    
    _providers = {}
    
    @classmethod
    def register_provider(cls, name: str, provider_class):
        """Register a storage provider class"""
        cls._providers[name] = provider_class
    
    @classmethod
    def create_provider_from_connection_string(cls, connection_string: str, config: dict) -> StorageProvider:
        """Create a storage provider instance from a connection string"""
        if not connection_string:
            raise ValueError("Connection string is required")
        
        # Parse the connection string to determine provider
        parsed = urlparse(connection_string)
        provider_name = parsed.scheme
        
        if provider_name not in cls._providers:
            available = ', '.join(cls._providers.keys())
            raise ValueError(f"Unknown provider '{provider_name}'. Available: {available}")
        
        # Add connection string to config
        config = config.copy()
        config['connection_string'] = connection_string
        
        provider_class = cls._providers[provider_name]
        return provider_class(config)
    
    @classmethod
    def create_provider(cls, provider_name: str, config: dict) -> StorageProvider:
        """Create a storage provider instance (legacy method)"""
        if provider_name not in cls._providers:
            available = ', '.join(cls._providers.keys())
            raise ValueError(f"Unknown provider '{provider_name}'. Available: {available}")
        
        provider_class = cls._providers[provider_name]
        return provider_class(config)
    
    @classmethod
    def list_providers(cls) -> List[str]:
        """List available storage providers"""
        return list(cls._providers.keys())