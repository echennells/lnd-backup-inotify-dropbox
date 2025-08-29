#!/bin/bash
set -e

echo "Uninstalling LND Backup Monitor..."

# Stop and disable service
systemctl --%SYSTEMD_SCOPE% stop lnd-backup.service 2>/dev/null || true
systemctl --%SYSTEMD_SCOPE% disable lnd-backup.service 2>/dev/null || true

# Remove files
rm -f "%SYSTEMD_DIR%/lnd-backup.service"
rm -f "%INSTALL_DIR%/lnd-backup-monitor"
rm -f "%INSTALL_DIR%/dropbox_backup.py"
rm -rf "%CONFIG_DIR%"
rm -rf "%CRED_DIR%"

# Reload systemd
systemctl --%SYSTEMD_SCOPE% daemon-reload

echo "Uninstalled successfully"
echo "Note: Python packages installed with pip were not removed"