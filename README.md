# LND & Taproot Assets Backup System

Automated backup system for LND channel.backup files and Taproot Assets database using inotify to detect changes and cloud storage.

⚠️ **CRITICAL WARNING FOR TAPROOT ASSETS** ⚠️

As of Taproot Assets v0.3.0+, according to Lightning Labs documentation:
- **There is NO recovery mechanism from lnd seed alone**
- **Loss of tapd database = PERMANENT loss of ALL Taproot Assets**
- **The BTC anchoring the assets will also become unspendable**
- **Regular backups (hourly or more frequent) are ESSENTIAL**

## Features

- **Automatic Detection**: Uses inotify to monitor channel.backup file changes with fallback polling
- **Taproot Assets Support**: Hourly backups of critical tapd database files (configurable frequency)
- **Multiple Storage Providers**: Supports Dropbox and Azure Blob Storage
- **Pluggable Architecture**: Easy to add new storage providers
- **Timestamped Backups**: Keeps timestamped versions of all backups
- **Latest Version**: Maintains a "latest" backup for easy access
- **Auto Cleanup**: Automatically removes old backups (configurable retention)
- **Docker Compatible**: Works with dockerized LND nodes
- **Local Installation**: Native systemd service installation
- **Secure Credentials**: Uses systemd-creds when available

## Prerequisites

- Ubuntu/Debian Linux system
- LND node (dockerized or native)
- Python 3.6+
- inotify-tools package
- Storage provider account (Dropbox or Azure)

## Installation

### System Installation

The backup system requires proper permissions to access LND's channel.backup file. The installer handles this automatically by:

- Creates `lndbackup` system user and group
- Sets up ACL permissions on LND data directories
- Handles directory traversal permissions for restrictive setups
- Configures systemd services to run as the `lndbackup` user

**Requirements:**
- Must be run with sudo privileges
- Automatically detects and configures permissions for your LND setup

**Manual Permission Fix (if needed):**
```bash
# Create bitcoin group and add users
sudo groupadd bitcoin
sudo usermod -a -G bitcoin lnd        # Add LND user to bitcoin group
sudo usermod -a -G bitcoin lndbackup  # Add backup user to bitcoin group

# Fix LND directory permissions
sudo chgrp -R bitcoin ~/.lnd/data
sudo chmod -R g+rx ~/.lnd/data
sudo chmod g+r ~/.lnd/data/chain/bitcoin/*/channel.backup
```

### 1. Clone the repository

```bash
cd /home/ubuntu
git clone https://github.com/echennells/lnd-backup-inotify-dropbox.git
cd lnd-backup-inotify-dropbox
```

### 2. Configure Storage Provider

#### Dropbox Setup
1. Go to https://www.dropbox.com/developers/apps
2. Click "Create app"
3. Choose "Scoped access"
4. Choose "Full Dropbox" or "App folder"
5. Name your app (e.g., "LND-Backup")
6. Click "Create app"
7. In the app settings, go to the "Permissions" tab and enable:
   - `files.metadata.write`
   - `files.content.write`
   - `files.content.read`
8. Go to the "Settings" tab
9. Under "OAuth 2", click "Generate" for Access Token
10. Copy the token

#### Azure Blob Storage Setup
1. Create an Azure Storage Account
2. Create a container for backups
3. Generate a SAS token with these permissions:
   - **Read** (r): Read blob contents
   - **Add** (a): Add new blobs
   - **Create** (c): Create new blobs  
   - **Write** (w): Write to blobs
   - **List** (l): List blobs in container
4. Use this URL format: `azure://account.blob.core.windows.net/container?sp=racwl&st=...&se=...&spr=https&sv=...&sr=c&sig=...`

**Important**: Ensure the SAS token has `sp=racwl` permissions, not just `sp=r` (read-only).

### 3. Automated Installation

```bash
# Set your storage connection string
export STORAGE_CONNECTION_STRING="dropbox:YOUR_DROPBOX_TOKEN"
# OR for Azure:
# export STORAGE_CONNECTION_STRING="azure://account.blob.core.windows.net/container?sp=racwl&..."

# Run the installer (requires sudo)
sudo ./install.sh

# Start the service
sudo systemctl enable --now lnd-backup
```

### 4. Manual Installation

```bash
# Install system packages
sudo apt update
sudo apt install -y inotify-tools python3-pip

# Install Python packages
pip3 install -r requirements.txt

# Test the backup manually
export STORAGE_CONNECTION_STRING="dropbox:YOUR_TOKEN"
python3 backup.py

# Copy service file
sudo cp lnd-backup.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable and start service
sudo systemctl enable --now lnd-backup

# Check service status
sudo systemctl status lnd-backup

# View logs
sudo journalctl -fu lnd-backup
```

## Configuration

The system uses a connection string approach for storage configuration:

### Storage Connection Strings
- **Dropbox**: `dropbox:YOUR_ACCESS_TOKEN`
- **Azure**: `azure://account.blob.core.windows.net/container?sp=racwl&...`

### Environment Variables
- `STORAGE_CONNECTION_STRING`: Storage provider connection string
- `NETWORK`: Bitcoin network (mainnet, testnet, signet, regtest)
- `CHECK_INTERVAL`: Seconds between fallback checks (default: 300)
- `ENABLE_TAPD`: Enable Taproot Assets backups (default: false)
- `LOG_LEVEL`: Logging level (debug, info, warn, error)

## File Structure

```
lnd-backup-inotify-dropbox/
├── backup.py                    # Main backup script with provider support
├── storage_providers.py         # Storage provider interface
├── dropbox_provider.py          # Dropbox storage implementation
├── azure_provider.py           # Azure Blob storage implementation
├── install.sh                  # Automated installation script
├── requirements.txt            # Python dependencies
├── templates/
│   ├── config                  # Configuration template
│   ├── lnd-backup-monitor.sh   # inotify monitoring script
│   ├── lnd-backup.service      # Systemd service template
│   ├── lnd-backup-wrapper.sh   # Service wrapper script
│   └── uninstall.sh           # Uninstall script template
└── README.md                   # This file
```

## How It Works

1. **Hybrid Monitoring**: Uses inotify to watch for channel.backup changes with fallback polling every 5 minutes
2. **Storage Abstraction**: Pluggable storage providers (Dropbox, Azure) with consistent interface
3. **Secure Credentials**: Uses systemd-creds or restricted files for credential storage
4. **Automatic Upload**: When changes detected, uploads to configured storage provider with timestamped naming
5. **Retention**: Old backups are automatically deleted based on configuration
6. **Service Management**: Systemd ensures the monitor runs continuously

## Monitoring

Check if backups are working:

```bash
# Check service status
sudo systemctl status lnd-backup

# View recent logs
sudo journalctl -u lnd-backup --since "1 hour ago"

# Follow logs in real-time
sudo journalctl -fu lnd-backup
```

## Recovery

### LND Channel Recovery

To restore from a channel backup:

1. Download the backup file from cloud storage
2. Stop LND
3. Place the backup file in the correct location
4. Start LND with recovery options

**Important**: Channel backups are only for disaster recovery. They allow you to request channel closure from peers but don't restore channel state.

### Taproot Assets Recovery

⚠️ **CRITICAL**: Taproot Assets recovery requires BOTH:
1. The lnd seed phrase (for private keys)
2. The complete tapd database backup (tapd.db, tapd.db-wal, tapd.db-shm)

To restore Taproot Assets:

1. Download the latest tapd backup archive from cloud storage
2. Stop tapd daemon
3. Extract the archive to restore:
   - Database files to `~/.tapd/data/<network>/`
   - Optional: proof files to `~/.tapd/data/<network>/proofs/`
4. Restart tapd daemon

**WARNING**: 
- Using an outdated backup is safe but you may lose access to newer assets
- There's no penalty mechanism like in Lightning
- NEVER delete the Lightning Terminal app in Umbrel without backing up tapd data first

## Troubleshooting

### Service won't start
```bash
sudo journalctl -u lnd-backup -n 50
```

### Dropbox authentication fails
- Regenerate token at https://www.dropbox.com/developers/apps
- Update token in `.env` file
- Restart service: `sudo systemctl restart lnd-backup`

### File not found errors
- Verify the path in `.env` matches your LND setup
- For Docker: ensure volumes are mounted correctly

### No backups appearing
- Check if you have any channels open
- channel.backup only exists after opening first channel

## Security Notes

- Keep your `.env` file secure (chmod 600)
- Never commit `.env` to git
- Regularly test your backups
- Store backup copies in multiple locations

## License

MIT

## Support

For issues or questions, please open an issue on GitHub.