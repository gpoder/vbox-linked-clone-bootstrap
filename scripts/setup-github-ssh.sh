
#!/usr/bin/env bash
set -e

USER_HOME="$HOME"
SSH_DIR="$USER_HOME/.ssh"
HOST="$(hostname -s)"
KEY="$SSH_DIR/id_github_${HOST}"
MARKER="$SSH_DIR/.github_ssh_done"
EMAIL="glenn.poder@github"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

if [[ -f "$MARKER" ]]; then
  exit 0
fi

ssh-keygen -t ed25519 -C "$EMAIL" -f "$KEY" -N ""

cat >> "$SSH_DIR/config" <<EOF
Host github.com
    HostName github.com
    User git
    IdentityFile $KEY
    IdentitiesOnly yes
EOF

chmod 600 "$SSH_DIR/config"

ssh-keyscan github.com >> "$SSH_DIR/known_hosts" 2>/dev/null
chmod 644 "$SSH_DIR/known_hosts"

gh ssh-key add "$KEY.pub" -t "$HOST" || true

touch "$MARKER"
