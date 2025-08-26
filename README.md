# LND & Taproot Assets Backup System

Automated backup system for LND channel.backup files and Taproot Assets database using inotify to detect changes and Dropbox for storage.

## Features

- **Automatic Detection**: Uses inotify to monitor channel.backup file changes
- **Taproot Assets Support**: Daily backups of critical tapd database files
- **Dropbox Integration**: Automatically uploads backups to Dropbox
- **Timestamped Backups**: Keeps timestamped versions of all backups
- **Latest Version**: Maintains a "latest" backup for easy access
- **Auto Cleanup**: Automatically removes old backups (configurable retention)
- **Docker Compatible**: Works with dockerized LND nodes
- **Systemd Service**: Runs as a system service with auto-restart

## Prerequisites

- Ubuntu/Debian Linux system
- LND node (dockerized or native)
- Python 3.6+
- inotify-tools package
- Dropbox account and API access token

## Installation

### 1. Clone the repository

```bash
cd /home/ubuntu
git clone https://github.com/echennells/lnd-backup-inotify-dropbox.git
cd lnd-backup-inotify-dropbox
```

### 2. Install dependencies

```bash
# Install system packages
sudo apt update
sudo apt install -y inotify-tools python3-pip

# Install Python packages
pip3 install -r requirements.txt
```

### 3. Configure Dropbox Access

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

### 4. Configure the backup system

```bash
# Copy the environment file
cp .env.example .env

# Edit .env and add your Dropbox token
nano .env
```

Update the `DROPBOX_ACCESS_TOKEN` with your token from step 3.

### 5. Test the backup script

```bash
# Make scripts executable
chmod +x channel-backup-monitor.sh
chmod +x dropbox_backup.py

# Test the backup manually
python3 dropbox_backup.py
```

### 6. Install systemd service

```bash
# Copy service file
sudo cp lnd-backup.service /etc/systemd/system/

# Reload systemd
sudo systemctl daemon-reload

# Enable service to start on boot
sudo systemctl enable lnd-backup

# Start the service
sudo systemctl start lnd-backup

# Check service status
sudo systemctl status lnd-backup

# View logs
sudo journalctl -fu lnd-backup
```

## Configuration

Edit the `.env` file to customize:

- `DROPBOX_ACCESS_TOKEN`: Your Dropbox API token
- `LND_CHANNEL_BACKUP_PATH`: Path to your channel.backup file
- `TAPD_ENABLED`: Enable Taproot Assets backups (default: false)
- `TAPD_DATA_DIR`: Path to tapd data directory
- `TAPD_BACKUP_INTERVAL`: Seconds between backups (86400 = daily)
- `DROPBOX_BACKUP_DIR`: Directory in Dropbox for backups
- `LOCAL_BACKUP_DIR`: Local directory for backup copies
- `KEEP_LAST_N_BACKUPS`: Number of backups to retain (default: 30)

## File Structure

```
lnd-backup-inotify-dropbox/
├── .env                      # Configuration (not in git)
├── .env.example              # Example configuration
├── dropbox_backup.py         # Python script for Dropbox upload
├── channel-backup-monitor.sh # Bash script using inotify
├── lnd-backup.service        # Systemd service definition
├── requirements.txt          # Python dependencies
└── README.md                 # This file
```

## How It Works

1. **inotify Monitor**: The `channel-backup-monitor.sh` script uses `inotifywait` to watch for changes to the channel.backup file
2. **Change Detection**: When LND updates the backup file (channel opened/closed), inotify triggers
3. **Dropbox Upload**: The Python script uploads the backup with timestamp
4. **Retention**: Old backups are automatically deleted based on configuration
5. **Service Management**: Systemd ensures the monitor runs continuously

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