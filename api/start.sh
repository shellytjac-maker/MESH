#!/bin/bash
set -e

export PATH="$HOME/.foundry/bin:$PATH"

# Start a local chain inside this same service -- this replaces the anvil
# terminal tab you were running in Codespaces. Nothing outside this
# container is needed for the demo to work.
anvil --host 0.0.0.0 --port 8545 &

# Give anvil a moment to finish booting before we deploy against it.
sleep 3

cd "$(dirname "$0")"

# Fresh chain every deploy -- redeploy the contracts and regenerate
# deployed.json, then start the API server that reads it.
node deploy.js
node server.js
