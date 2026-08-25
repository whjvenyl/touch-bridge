#!/bin/bash
set -euo pipefail

# TouchBridge PAM Activator
# Enables the TouchBridge PAM hook for sudo (and screensaver).
# For users who installed via Homebrew or the .pkg — binaries are already in
# place, this only activates the hook.
#
# On macOS Sonoma+ this writes to the unprotected /etc/pam.d/sudo_local hook
# rather than the SIP-protected /etc/pam.d/sudo (see pam-common.sh).
#
# Usage: sudo bash patch-pam.sh

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=pam-common.sh
source "$SCRIPT_DIR/pam-common.sh"

PAM_LIB="/usr/local/lib/pam/pam_touchbridge.so"

echo "=== TouchBridge PAM Activator ==="
echo ""

if [ "$(id -u)" -ne 0 ]; then
    echo -e "\033[0;31m[ERROR]\033[0m This script must be run with sudo."
    echo "  Usage: sudo bash patch-pam.sh"
    exit 1
fi

if [ ! -f "$PAM_LIB" ]; then
    echo -e "\033[0;31m[ERROR]\033[0m PAM module not found at $PAM_LIB."
    echo -e "\033[0;31m[ERROR]\033[0m Install TouchBridge first (brew install --cask touchbridge, or the .pkg)."
    exit 1
fi
_tb_info "Found PAM module: $PAM_LIB"

# Ask about ignore_ssh
echo ""
echo "Skip TouchBridge when connected over SSH?"
echo "  This prevents biometric prompts when you SSH into this Mac."
echo "  (checks SSH_CLIENT, SSH_CONNECTION, SSH_TTY environment variables)"
read -p "Enable ignore_ssh? [y/N] " -n 1 -r
echo ""
if [[ $REPLY =~ ^[Yy]$ ]]; then
    TB_PAM_LINE="$TB_PAM_LINE_SSH"
    _tb_info "ignore_ssh enabled — SSH sessions will fall through to password."
fi

tb_enable_sudo "prompt"
tb_enable_screensaver "prompt"

echo ""
_tb_info "Done. Test with: sudo echo 'TouchBridge works!'"
echo "To undo, run uninstall.sh (or 'sudo bash patch-pam.sh' is safe to re-run)."
