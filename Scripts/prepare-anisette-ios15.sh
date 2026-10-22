#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
# Compatibility entry point. Production project.yml now depends on the canonical
# local package; do not create a second AnisetteKit under build/Dependencies.
echo 'Preparing the production AnisetteKit dependency; remote remains the runtime default.'
bash "$ROOT/Scripts/build-on-device-anisette.sh"
