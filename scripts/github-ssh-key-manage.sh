#!/usr/bin/env bash
set -euo pipefail

# github-ssh-key-manage.sh
# - Lists GitHub SSH keys via gh
# - Interactive bulk delete by selecting numbers
# - Self-delete mode deletes key whose title == hostname (safe for VM destroy)

usage() {
  cat <<'EOF'
Usage:
  github-ssh-key-manage.sh [options]

Options:
  --list               List keys (default behavior)
  --delete             Interactive delete (select numbers)
  --self-delete        Delete key with title == $(hostname -s)
  --match PREFIX       Delete keys whose title starts with PREFIX (interactive confirm)
  --yes                Skip "are you sure" confirmations (dangerous)
  -h, --help           Show help

Dependencies:
  - gh (authenticated)
  - jq (recommended for reliable parsing)

Notes:
  - Keys are identified by GitHub numeric id.
  - This script uses: gh ssh-key list --json id,title

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

command -v gh >/dev/null 2>&1 || { echo "gh not installed" >&2; exit 2; }
gh auth status >/dev/null 2>&1 || { echo "gh not authenticated. Run: gh auth login" >&2; exit 3; }

# Prefer jq for correctness
if ! command -v jq >/dev/null 2>&1; then
  echo "jq not installed. Install: sudo apt install -y jq" >&2
  exit 4
fi

fetch_json() {
  # gh ssh-key list supports --json in modern gh; you already have it.
  gh ssh-key list --json id,title
}

print_numbered() {
  local json="$1"
  echo
  echo "GitHub SSH keys:"
  echo "----------------"
  echo "$json" | jq -r '.[] | "\(.id)\t\(.title)"' | nl -w2 -s'. '
}

confirm() {
  local prompt="$1"
  if $ASSUME_YES; then return 0; fi
  read -rp "$prompt (y/N): " ans
  [[ "${ans,,}" == "y" ]]
}

delete_ids() {
  local ids=("$@")
  for id in "${ids[@]}"; do
    [[ -n "$id" ]] || continue
    gh ssh-key delete "$id" --yes
  done
}

case "$MODE" in
  list)
    json="$(fetch_json)"
    print_numbered "$json"
    ;;

  self)
    host="$(hostname -s)"
    json="$(fetch_json)"
    id="$(echo "$json" | jq -r --arg t "$host" '.[] | select(.title==$t) | .id' | head -n1)"

    if [[ -z "$id" || "$id" == "null" ]]; then
      echo "No GitHub SSH key found with title: $host"
      exit 0
    fi

    echo "Found key id=$id title=$host"
    confirm "Delete this key?" || exit 0
    delete_ids "$id"
    echo "Deleted key: $host"
    ;;

  match)
    [[ -n "$MATCH_PREFIX" ]] || { echo "--match requires PREFIX" >&2; exit 1; }
    json="$(fetch_json)"
    print_numbered "$json"

    mapfile -t ids < <(echo "$json" | jq -r --arg p "$MATCH_PREFIX" '.[] | select(.title|startswith($p)) | .id')
    mapfile -t titles < <(echo "$json" | jq -r --arg p "$MATCH_PREFIX" '.[] | select(.title|startswith($p)) | .title')

    if [[ ${#ids[@]} -eq 0 ]]; then
      echo "No keys matched prefix: $MATCH_PREFIX"
      exit 0
    fi

    echo
    echo "Keys to delete (prefix: $MATCH_PREFIX):"
    for i in "${!ids[@]}"; do
      echo "  id=${ids[$i]} title=${titles[$i]}"
    done

    confirm "Delete ALL matched keys?" || exit 0
    delete_ids "${ids[@]}"
    echo "Deleted ${#ids[@]} keys."
    ;;

  delete)
    json="$(fetch_json)"
    print_numbered "$json"

    total="$(echo "$json" | jq 'length')"
    [[ "$total" -gt 0 ]] || { echo "No keys found."; exit 0; }

    echo
    read -rp "Enter numbers to delete (e.g. 1 3 5): " selection

    # Build array index -> id mapping
    # jq arrays are 0-based; user input is 1-based
    ids_to_delete=()
    for n in $selection; do
      [[ "$n" =~ ^[0-9]+$ ]] || { echo "Invalid selection: $n" >&2; exit 1; }
      idx=$((n-1))
      id="$(echo "$json" | jq -r ".[$idx].id")"
      title="$(echo "$json" | jq -r ".[$idx].title")"
      [[ "$id" != "null" ]] || { echo "Selection out of range: $n" >&2; exit 1; }
      ids_to_delete+=("$id")
      echo "Selected: id=$id title=$title"
    done

    echo
    confirm "Delete selected keys?" || exit 0
    delete_ids "${ids_to_delete[@]}"
    echo "Done."
    ;;

  *)
    echo "Unknown mode" >&2
    exit 1
    ;;
esac
