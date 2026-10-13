#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tools/lib/build_inputs.sh
source "${SCRIPT_DIR}/lib/build_inputs.sh"

resolve_build_inputs
write_build_inputs
