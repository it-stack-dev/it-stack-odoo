#!/bin/bash
# entrypoint.sh — IT-Stack odoo container entrypoint
set -euo pipefail

echo "Starting IT-Stack ODOO (Module 13)..."

# Source any environment overrides
if [ -f /opt/it-stack/odoo/config.env ]; then
    # shellcheck source=/dev/null
    source /opt/it-stack/odoo/config.env
fi

# Execute the upstream entrypoint or command
exec "$$@"
