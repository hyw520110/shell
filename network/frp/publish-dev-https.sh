#!/usr/bin/env bash
# Compatibility wrapper. The generic implementation lives in ../publish-dev-https.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "${SCRIPT_DIR}/../publish-dev-https.sh" "$@"
