#!/usr/bin/env bash
set -euo pipefail

# vbox-clone-destroy.sh (HOST script)
# - Interactive VM selection
# - Poweroff + unregister --delete
# - Optionally delete GitHub SSH key with title == VM name (requires gh auth on host)
# - Dry-run support

usage() {
  cat <<'EOF'
Usage:
  vbox-clone-destroy.sh [options]

Options:
  --filter REGEX          Only show VMs whose names match REGEX
  --github-delete         Delete GitHub SSH key with title == VM name (requires gh auth on host)
  --no-github-delete      Do not touch GitHub (default)
  --dry-run               Print actions without executing
  --force                 Skip confirmations (dangerous)
  -h, --help              Show help

Notes:
- VM deletion uses: VBoxManage unregistervm "<vm>" --delete
- GitHub key deletion finds keys by title exactly matching VM name.

EOF
}

FILTER=""
DO_GITHUB_DELETE=false
DRY_RUN=false
FORCE=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --filter) FILTER="$2"; shift 2 ;;
    --github-delete) DO_GITHUB_DELETE=true; shift ;;
    --no-github-delete) DO_GITHUB_DELETE=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --force) FORCE=true; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown option: $1" >&2; usage; exit 1 ;;
  esac
done

need() { command -v "$1" >/dev/null 2>&1 || { echo "Missing: $1" >&2; exit 2; }; }
need VBoxManage

run() {
  if $DRY_RUN; then
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    echo
  else
    "$@"
  fi
}

confirm() {
  local prompt="$1"
  $FORCE && return 0
  read -rp "$prompt (y/N): " ans
  [[ "${ans,,}" == "y" ]]
}

# Fetch VM list
mapfile -t ALL_VMS < <(VBoxManage list vms | awk -F\" '{print $2}')

if [[ ${#ALL_VMS[@]} -eq 0 ]]; then
  echo "No VMs found."
  exit 0
fi

# Apply filter
VMS=()
if [[ -n "$FILTER" ]]; then
  for vm in "${ALL_VMS[@]}"; do
    if [[ "$vm" =~ $FILTER ]]; then
      VMS+=("$vm")
    fi
  done
else
  VMS=("${ALL_VMS[@]}")
fi

if [[ ${#VMS[@]} -eq 0 ]]; then
  echo "No VMs match filter: $FILTER"
  exit 0
fi

echo
echo "Available VMs:"
for i in "${!VMS[@]}"; do
  printf "%2d. %s\n" $((i+1)) "${VMS[$i]}"
done

echo
read -rp "Select VMs to destroy (numbers, e.g. 1 3 5): " selection
[[ -n "$selection" ]] || { echo "Nothing selected."; exit 0; }

# Optional GitHub deletion precheck
if $DO_GITHUB_DELETE; then
  need gh
  if ! gh auth status >/dev/null 2>&1; then
    echo "Host gh is not authenticated. Either run 'gh auth login' or use --no-github-delete" >&2
    exit 3
  fi
  need jq
fi

selected_vms=()
for n in $selection; do
  [[ "$n" =~ ^[0-9]+$ ]] || { echo "Invalid selection: $n" >&2; exit 1; }
  idx=$((n-1))
  [[ $idx -ge 0 && $idx -lt ${#VMS[@]} ]] || { echo "Out of range: $n" >&2; exit 1; }
  selected_vms+=("${VMS[$idx]}")
done

echo
echo "Will destroy:"
for vm in "${selected_vms[@]}"; do
  echo "  - $vm"
done

echo
confirm "Proceed with VM deletion?" || exit 0

delete_github_key_by_title() {
  local title="$1"

  # Find key id by exact title match
  local json id
  json="$(gh ssh-key list --json id,title)"
  id="$(echo "$json" | jq -r --arg t "$title" '.[] | select(.title==$t) | .id' | head -n1)"

  if [[ -z "$id" || "$id" == "null" ]]; then
    echo "GitHub: no key found with title '$title' (skipping)"
    return 0
  fi

  echo "GitHub: deleting key title='$title' id=$id"
  run gh ssh-key delete "$id" --yes
}

for vm in "${selected_vms[@]}"; do
  echo
  echo "== Destroying VM: $vm =="

  # Delete GitHub key first (optional)
  if $DO_GITHUB_DELETE; then
    delete_github_key_by_title "$vm"
  fi

  # Power off VM (ignore failures if already off)
  run VBoxManage controlvm "$vm" poweroff || true

  # Unregister + delete disks
  run VBoxManage unregistervm "$vm" --delete
done

echo
echo "Done."
