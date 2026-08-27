#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# Render runs a single instance. Apply the small, idempotent schema repairs
# before accepting traffic so code and schema cannot drift across deploys.
MIX_ENV=prod mix ecto.migrate
exec env MIX_ENV=prod mix phx.server
