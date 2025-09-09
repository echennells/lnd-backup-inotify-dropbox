#!/bin/bash
set -euo pipefail

# DO NOT read credentials here!
# Python will securely read from either:
# - CREDENTIALS_DIRECTORY (systemd LoadCredential)
# - STORAGE_CONNECTION_STRING_FILE (fallback for older systemd)
# This keeps secrets out of shell environment variables

# Set Python path to use virtual environment
export PATH="%VENV_DIR%/bin:$PATH"

# Execute the actual monitor script
exec %INSTALL_DIR%/tapd-backup-monitor "$@"