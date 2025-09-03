# LND & Taproot Assets Backup System

Automated backup system for LND channel.backup files and Taproot Assets database using inotify to detect changes and Dropbox for storage.

## Features

- **Automatic Detection**: Uses inotify to monitor channel.backup file changes with fallback polling
- **Taproot Assets Support**: Daily backups of critical tapd database files
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
2. Get the connection string from Azure Portal
3. Format: `DefaultEndpointsProtocol=https;AccountName=...;AccountKey=...;EndpointSuffix=core.windows.net`

### 3. Automated Installation

```bash
# Set your storage connection string
export STORAGE_CONNECTION_STRING="dropbox:YOUR_DROPBOX_TOKEN"
# OR for Azure:
# export STORAGE_CONNECTION_STRING="azure:YOUR_CONNECTION_STRING"

# Run the installer
./install.sh

# Start the service
sudo systemctl enable --now lnd-backup
# OR for user installation:
# systemctl --user enable --now lnd-backup
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
- **Azure**: `azure:YOUR_CONNECTION_STRING`

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

To restore from a backup:

1. Download the backup file from Dropbox
2. Stop LND
3. Place the backup file in the correct location
4. Start LND with recovery options

**Important**: Channel backups are only for disaster recovery. They allow you to request channel closure from peers but don't restore channel state.

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