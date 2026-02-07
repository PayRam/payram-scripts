#!/bin/bash
# Run PayRam setup with all config/data in the current project directory.
# No changes to ~/.payraminfo or ~/.payram-core; everything stays here.
# Usage: ./run_local.sh [same args as script.sh, e.g. --testnet]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
cd "$SCRIPT_DIR"

export PAYRAM_LOCAL_SETUP=1
export PAYRAM_INFO_DIR="${SCRIPT_DIR}/.payraminfo"
export PAYRAM_CORE_DIR="${SCRIPT_DIR}/.payram-core"
export LOG_FILE="${SCRIPT_DIR}/.payram-setup.log"

echo "PayRam local setup: config and data in this directory"
echo "  PAYRAM_INFO_DIR=$PAYRAM_INFO_DIR"
echo "  PAYRAM_CORE_DIR=$PAYRAM_CORE_DIR"
echo "  LOG_FILE=$LOG_FILE"
echo "  After setup, use ./headless.sh for CLI-only operations (setup, signin, create-payment-link)."
echo "  If you just ran ./headless.sh reset-local, choose option 1 (Install PayRam) to deploy a new container."
echo ""

exec sudo -E ./script.sh "$@"
