#!/bin/bash
set -euo pipefail

# Load storage connection string from file if needed
if [[ -n "${STORAGE_CONNECTION_STRING_FILE:-}" ]] && [[ -f "${STORAGE_CONNECTION_STRING_FILE}" ]]; then
    export STORAGE_CONNECTION_STRING="$(cat "${STORAGE_CONNECTION_STRING_FILE}")"
elif [[ -n "${CREDENTIALS_DIRECTORY:-}" ]] && [[ -f "${CREDENTIALS_DIRECTORY}/storage.connection" ]]; then
    export STORAGE_CONNECTION_STRING="$(cat "${CREDENTIALS_DIRECTORY}/storage.connection")"
fi

# Set Python path to use virtual environment
export PATH="%VENV_DIR%/bin:$PATH"

# Execute the actual monitor script
exec %INSTALL_DIR%/lnd-backup-monitor "$@"