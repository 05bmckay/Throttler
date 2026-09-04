#!/usr/bin/env bash
set -euo pipefail
export MIX_ENV=prod
mix deps.get --only prod
mix compile --warnings-as-errors
mix release --overwrite
# Migrations run separately during the documented cutover, never from a build
# that overlaps a still-running older dispatcher.
