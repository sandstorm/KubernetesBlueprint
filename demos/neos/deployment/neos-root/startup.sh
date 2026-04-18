#!/bin/bash
# All startup tasks (migrations, site import, resource publishing)
# now run in entrypoint.sh before the web server starts.
echo "Startup tasks already completed in entrypoint.sh."

./flow resource:publish --collection static