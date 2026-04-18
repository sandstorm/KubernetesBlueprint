#!/bin/bash
set -ex

# IMPORTANT: Do not run flow:cache:flush here — it runs in entrypoint.sh
# before caretakerd starts, to avoid race conditions.

./flow cr:setup

# Import demo site on first run (if no site exists yet)
if ! ./flow site:list 2>/dev/null | grep -q "Neos.Demo"; then
    echo "First run — importing Neos demo site..."
    ./flow site:import --package-key Neos.Demo || true
    echo "Creating admin user (admin / admin)..."
    ./flow user:create --roles Administrator admin admin Admin User || true
fi

./flow resource:publish --collection static
