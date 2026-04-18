#!/bin/bash
set -ex

# 1. Run steps that must not be parallelized before caretakerd starts.
#    Otherwise race conditions lead to partial cache builds and broken state.

./flow flow:cache:flush
./flow doctrine:migrate
./flow cr:setup

# Import demo site on first run (if no site exists yet)
if ! ./flow site:list 2>/dev/null | grep -q "Neos.Demo"; then
    echo "First run — importing Neos demo site..."
    ./flow site:importall --packagekey Neos.Demo

    ./flow user:create --roles Administrator admin "$NEOS_ADMIN_PASSWORD" Admin User
fi

# 2. Start caretakerd, which runs FrankenPHP (startup.sh is now a no-op)
/usr/bin/caretakerd run
