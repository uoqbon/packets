#!/usr/bin/env bash
# cloud-setup.sh: provisions a Claude Code cloud session (Ubuntu 24.04) for the offline tests, which need
# PowerShell 7.2+ and git 2.38+ (CONTRIBUTING.md). The image has git and gh but not pwsh.
#
# Paste this file into the cloud environment's Setup script field, where it runs as root and its result is
# cached. The SessionStart hook in .claude/settings.json runs it too, as a fallback for an environment
# without the setup script; there it does nothing outside the cloud or once pwsh is installed.
set -euo pipefail

if [ -n "${CLAUDE_PROJECT_DIR:-}" ] && [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then exit 0; fi
if command -v pwsh >/dev/null 2>&1; then exit 0; fi

sudo=''
if [ "$(id -u)" -ne 0 ]; then sudo='sudo'; fi

# Microsoft's apt repository (packages.microsoft.com is on the Trusted network allowlist).
. /etc/os-release
deb="$(mktemp --suffix=.deb)"
curl -fsSL "https://packages.microsoft.com/config/ubuntu/${VERSION_ID}/packages-microsoft-prod.deb" -o "$deb"
$sudo dpkg -i "$deb"
rm -f "$deb"
$sudo apt-get update -qq
$sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq powershell >/dev/null

pwsh -NoProfile -Command '"pwsh $($PSVersionTable.PSVersion)"'
git --version
