#!/usr/bin/env bash
set -euo pipefail

# github-ssh-key-manage.sh
# Uses: gh api user/keys (works on old gh)
#
# Requires:
#   - gh (authenticated)
#   - jq
#
# Keys are identified reliably by:
#   - id
#   - title

usage() {
  cat <<'EOF'
Usage:
  github-ssh-key-manage.sh [options]

Options:
  --list               List GitHub SSH keys (default)
  --delete             Interactive delete (select numbers)
  --self-delete        Delete key with title == hostname -s
  --match PREFIX       Delete keys whose title starts with PREFIX
  --yes                Skip confirmation prompts
  -h, --help           Show this help

Examples:
  github-ssh-key-manage --list
  github-ssh-key-manage --delete
  github-ssh-key-manage --self-delete
  github-ssh-key-manage --match newvm
EOF
}

MODE="list"
MATCH_PREFIX=""
ASSUME_YES=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --list) MODE="list"; shift ;;
    --delete) MODE="delete"; shift ;;
    --self-delete) MODE="self"; shift ;;
    --match) MODE="match"; MATCH_PREFIX="$2"; shift 2 ;;
    --yes) ASSUME_YES=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 2; }; }
need gh
need jq

gh auth status >/dev/null 2>&1 || {
  echo "gh not authenticated. Run: gh auth login" >&2
  exit 3
}

confirm() {
  local prompt="$1"
  $ASSUME_YES && return 0
  read -rp "$prompt (y/N): " ans
  [[ "${ans,,}" == "y" ]]
}

# Fetch keys as JSON once
KEYS_JSON="$(gh api user/keys)"

# Normalized table:
#   id<TAB>title
keys_table() {
  echo "$KEYS_JSON" | jq -r '.[] | "\(.id)\t\(.title)"'
}

print_numbered() {
  local table="$1"
  echo
  echo "GitHub SSH keys:"
  echo "----------------"
  echo "$table" | nl -w2 -s'. ' | sed $'s/\t/  |  /'
}

delete_key_id() {
  local id="$1"
  gh api --method DELETE "user/keys/$id" >/dev/null
}

case "$MODE" in
  list)
    table="$(keys_table)"
    if [[ -z "$table" ]]; then
      echo "No SSH keys found."
      exit 0
    fi
    print_numbered "$table"
    ;;

  delete)
    table="$(keys_table)"
    [[ -n "$table" ]] || { echo "No SSH keys found."; exit 0; }

    print_numbered "$table"
    mapfile -t ids < <(echo "$table" | awk -F'\t' '{print $1}')
    mapfile -t titles < <(echo "$table" | awk -F'\t' '{print $2}')

    echo
    read -rp "Enter numbers to delete (e.g. 1 3 5): " selection
    [[ -n "${selection// }" ]] || { echo "Nothing selected."; exit 0; }

    to_delete=()
    for n in $selection; do
      [[ "$n" =~ ^[0-9]+$ ]] || { echo "Invalid selection: $n" >&2; exit 1; }
      idx=$((n-1))
      [[ $idx -ge 0 && $idx -lt ${#ids[@]} ]] || { echo "Out of range: $n" >&2; exit 1; }
      echo "Selected: id=${ids[$idx]} title=${titles[$idx]}"
      to_delete+=("${ids[$idx]}")
    done

    echo
    confirm "Delete selected keys?" || exit 0
    for id in "${to_delete[@]}"; do delete_key_id "$id"; done
    echo "Done."
    ;;

  self)
    host="$(hostname -s)"
    match_id="$(echo "$KEYS_JSON" \
      | jq -r --arg h "$host" '.[] | select(.title==$h) | .id' | head -n1)"

    if [[ -z "$match_id" ]]; then
      echo "No key found with title: $host"
      exit 0
    fi

    echo "Matched key id=$match_id title=$host"
    confirm "Delete this key?" || exit 0
    delete_key_id "$match_id"
    echo "Deleted."
    ;;

  match)
    [[ -n "$MATCH_PREFIX" ]] || { echo "--match requires PREFIX" >&2; exit 1; }

    mapfile -t ids < <(
      echo "$KEYS_JSON" | jq -r --arg p "$MATCH_PREFIX" \
        '.[] | select(.title | startswith($p)) | .id'
    )

    [[ ${#ids[@]} -gt 0 ]] || {
      echo "No keys matched prefix: $MATCH_PREFIX"
      exit 0
    }

    echo "Matched ${#ids[@]} keys."
    confirm "Delete ALL matched keys?" || exit 0
    for id in "${ids[@]}"; do delete_key_id "$id"; done
    echo "Done."
    ;;

  *)
    echo "Unknown mode" >&2
    exit 1
    ;;
esac
