#!/usr/bin/env bash
set -euo pipefail

# github-ssh-key.sh
# - Always generates a per-host GitHub SSH key (idempotent)
# - Optionally uploads it to GitHub via gh (flag-controlled)
# - Pre-seeds GitHub host key into known_hosts to avoid prompts

EMAIL_DEFAULT="glenn.poder@github"

usage() {
  cat <<'EOF'
Usage:
  github-ssh-key.sh [options]

Options:
  --email EMAIL        Key comment/email (default: glenn.poder@github)
  --upload             Upload generated key to GitHub using gh
  --no-upload          Do not upload (default)
  --print              Print paths and public key
  --force              Regenerate even if marker exists (DANGEROUS: new key)
  -h, --help           Show help

Notes:
- Key path: ~/.ssh/id_github_<hostname>
- Marker:   ~/.ssh/.github_ssh_done
- Upload uses: gh ssh-key add <pubkey> -t <hostname>

EOF
}

EMAIL="$EMAIL_DEFAULT"
DO_UPLOAD=false
DO_PRINT=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --email) EMAIL="$2"; shift 2 ;;
    --upload) DO_UPLOAD=true; shift ;;
    --no-upload) DO_UPLOAD=false; shift ;;
    --print) DO_PRINT=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

HOST="$(hostname -s)"
SSH_DIR="$HOME/.ssh"
KEY="$SSH_DIR/id_github_${HOST}"
PUB="${KEY}.pub"
MARKER="$SSH_DIR/.github_ssh_done"
CFG="$SSH_DIR/config"
KNOWN="$SSH_DIR/known_hosts"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$MARKER" && "$FORCE" == "false" ]]; then
  $DO_PRINT && { echo "Key already prepared: $PUB"; echo; cat "$PUB" || true; }
  exit 0
fi

if [[ "$FORCE" == "true" ]]; then
  rm -f "$KEY" "$PUB" "$MARKER"
fi

# Generate key (non-interactive)
ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY" -N ""

# Ensure GitHub host config exists (append only if missing)
if ! grep -qE '^\s*Host\s+github\.com\s*$' "$CFG" 2>/dev/null; then
  cat >> "$CFG" <<EOF

Host github.com
    HostName github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF
fi

chmod 600 "$CFG"

# Pre-seed known_hosts to avoid interactive verification prompts
ssh-keyscan github.com >> "$KNOWN" 2>/dev/null || true
chmod 644 "$KNOWN"

touch "$MARKER"

if $DO_UPLOAD; then
  command -v gh >/dev/null 2>&1 || { echo "gh not installed; cannot upload" >&2; exit 2; }

  # Require auth
  if ! gh auth status >/dev/null 2>&1; then
    echo "gh is not authenticated. Run: gh auth login" >&2
    exit 3
  fi

  # Old gh compatibility: use -t (not --title)
  gh ssh-key add "$PUB" -t "$HOST"
fi

if $DO_PRINT; then
  echo "Host : $HOST"
  echo "Key  : $KEY"
  echo "Pub  : $PUB"
  echo
  cat "$PUB"
fi
