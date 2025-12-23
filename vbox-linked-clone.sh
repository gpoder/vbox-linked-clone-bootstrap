#!/usr/bin/env bash
set -euo pipefail

# ======================================================
# Defaults (do NOT unset under set -u)
# ======================================================
SSH_USER="ziggy"
SSH_PASS="cookie"
USE_SSHPASS=false

HEADLESS=true
DRY_RUN=false
DEBUG=false
PRINT_VARS=false
STOP_AFTER=""

SNAPSHOT="base-clean"

SOURCE_VM=""
NEW_VM=""
NEW_HOSTNAME=""
CONFIG_NIC=""
SSH_NIC=""
NET_MODE=""

GITHUB_KEY_CREATE=true
GITHUB_KEY_UPLOAD=false

# ======================================================
# Helpers
# ======================================================
section() {
  echo
  echo "======================================================"
  echo "$1"
  echo "======================================================"
}

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

need() {
  command -v "$1" >/dev/null 2>&1 || fail "Missing required command: $1"
}

run() {
  if $DRY_RUN; then
    printf 'DRY-RUN: '
    printf '%q ' "$@"
    echo
  else
    "$@"
  fi
}

stop_if_requested() {
  local stage="$1"
  local stop="${STOP_AFTER:-}"
  if [[ -n "$stop" && "$stop" == "$stage" ]]; then
    echo
    echo "🛑 STOPPED after stage: $stage"
    exit 0
  fi
}

run_ssh() {
  local cmd="$*"
  if $DRY_RUN; then
    if $USE_SSHPASS; then
      echo "DRY-RUN: sshpass -p '$SSH_PASS' ssh ${SSH_USER}@${IP} -- $cmd"
    else
      echo "DRY-RUN: ssh ${SSH_USER}@${IP} -- $cmd"
    fi
    return 0
  fi

  if $USE_SSHPASS; then
    need sshpass
    sshpass -p "$SSH_PASS" ssh -o StrictHostKeyChecking=no \
      "${SSH_USER}@${IP}" -- "$cmd"
  else
    ssh -o StrictHostKeyChecking=no "${SSH_USER}@${IP}" -- "$cmd"
  fi
}

wait_for_ssh() {
  $DRY_RUN && return 0

  for _ in {1..90}; do
    if $USE_SSHPASS; then
      # Password bootstrap mode (allow password auth)
      sshpass -p "$SSH_PASS" ssh \
        -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${IP}" "echo ok" >/dev/null 2>&1 && return 0
    else
      # Key-based / non-interactive mode
      ssh \
        -o BatchMode=yes \
        -o ConnectTimeout=3 \
        -o StrictHostKeyChecking=no \
        "${SSH_USER}@${IP}" "echo ok" >/dev/null 2>&1 && return 0
    fi
    sleep 2
  done

  return 1
}

snapshot_exists() {
  VBoxManage snapshot "$SOURCE_VM" list --machinereadable 2>/dev/null \
    | grep -q "^SnapshotName=\"$SNAPSHOT\"$"
}

print_all_ips() {
  local vm="$1"
  local found=false

  echo "IP Addresses:"
  for nic in {1..8}; do
    local prop="/VirtualBox/GuestInfo/Net/$((nic-1))/V4/IP"
    local raw ip

    raw=$(VBoxManage guestproperty get "$vm" "$prop" 2>/dev/null || true)
    ip=$(awk '{print $2}' <<<"$raw")

    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      printf "  NIC%-2s : %s\n" "$nic" "$ip"
      found=true
    fi
  done

  $found || echo "  (no IP addresses reported)"
}

# ======================================================
# Argument parsing
# ======================================================
while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) SOURCE_VM="$2"; shift 2 ;;
    --name) NEW_VM="$2"; NEW_HOSTNAME="$2"; shift 2 ;;
    --hostname) NEW_HOSTNAME="$2"; shift 2 ;;
    --config-nic) CONFIG_NIC="$2"; shift 2 ;;
    --ssh-nic) SSH_NIC="$2"; shift 2 ;;
    --network) NET_MODE="$2"; shift 2 ;;
    --snapshot) SNAPSHOT="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --use-sshpass) USE_SSHPASS=true; shift ;;
    --pass) SSH_PASS="$2"; shift 2 ;;
    --gui) HEADLESS=false; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --debug) DEBUG=true; shift ;;
    --stop-after) STOP_AFTER="$2"; shift 2 ;;
    --print-vars) PRINT_VARS=true; shift ;;
    --github-key-upload) GITHUB_KEY_UPLOAD=true; shift ;;
    --no-github-key) GITHUB_KEY_CREATE=false; shift ;;
    -h|--help)
      cat <<EOF
Usage:
  $0 --base VM --name NAME --config-nic N --network MODE [options]

Required:
  --base VM
  --name NAME
  --config-nic N        NIC to configure (1–8)
  --network MODE        nat | bridged | hostonly | natnetwork

Optional:
  --ssh-nic N           NIC to use for SSH/IP (auto-detect if omitted)
  --snapshot NAME       Snapshot name (default: base-clean)
  --dry-run
  --print-vars

GitHub SSH:
  --github-key-upload     Upload generated GitHub SSH key
  --no-github-key         Do not generate GitHub SSH key

EOF
      exit 0 ;;
    *) fail "Unknown option: $1" ;;
  esac
done

$DEBUG && set -x

# ======================================================
section "validate"
# ======================================================
need VBoxManage
need ssh

[[ -n "$SOURCE_VM" && -n "$NEW_VM" && -n "$CONFIG_NIC" && -n "$NET_MODE" ]] \
  || fail "Missing required arguments"

[[ "$CONFIG_NIC" =~ ^[1-8]$ ]] || fail "--config-nic must be 1–8"
[[ -z "$SSH_NIC" || "$SSH_NIC" =~ ^[1-8]$ ]] || fail "--ssh-nic must be 1–8"

VBoxManage showvminfo "$SOURCE_VM" >/dev/null || fail "Source VM not found"

STATE=$(VBoxManage showvminfo "$SOURCE_VM" --machinereadable \
        | awk -F= '/^VMState=/{gsub(/"/,"",$2);print $2}')
[[ "$STATE" == "poweroff" ]] || fail "Base VM must be powered off"

VBoxManage showvminfo "$NEW_VM" >/dev/null 2>&1 && \
  fail "Target VM already exists"

stop_if_requested "validate"

# ======================================================
section "snapshot"
# ======================================================
if snapshot_exists; then
  echo "Using existing snapshot: $SNAPSHOT"
else
  run VBoxManage snapshot "$SOURCE_VM" take "$SNAPSHOT" \
    --description "Base snapshot for linked clones"
fi

stop_if_requested "snapshot"

# ======================================================
section "clone"
# ======================================================
run VBoxManage clonevm "$SOURCE_VM" \
  --snapshot "$SNAPSHOT" \
  --name "$NEW_VM" \
  --register \
  --options link

stop_if_requested "clone"

# ======================================================
section "mac"
# ======================================================
# Regenerate MAC addresses to avoid DHCP collisions
for nic in "$CONFIG_NIC" "${SSH_NIC:-}"; do
  [[ -n "$nic" ]] || continue
  run VBoxManage modifyvm "$NEW_VM" --macaddress${nic} auto
done

stop_if_requested "mac"

# ======================================================
section "network"
# ======================================================
run VBoxManage modifyvm "$NEW_VM" --nic${CONFIG_NIC} "$NET_MODE"

case "$NET_MODE" in
  bridged)
    IFACE=$(VBoxManage list bridgedifs | awk -F': ' '/^Name:/{print $2; exit}' | xargs)
    run VBoxManage modifyvm "$NEW_VM" --bridgeadapter${CONFIG_NIC} "$IFACE"
    ;;
  hostonly)
    IFACE=$(VBoxManage list hostonlyifs | awk -F': ' '/^Name:/{print $2; exit}')
    run VBoxManage modifyvm "$NEW_VM" --hostonlyadapter${CONFIG_NIC} "$IFACE"
    ;;
  natnetwork)
    NATNET=$(VBoxManage showvminfo "$SOURCE_VM" --machinereadable \
             | awk -F'"' '/nat-network/{print $2; exit}')
    run VBoxManage modifyvm "$NEW_VM" --nat-network${CONFIG_NIC} "$NATNET"
    ;;
esac

stop_if_requested "network"

# ======================================================
section "start"
# ======================================================
run VBoxManage startvm "$NEW_VM" --type "$($HEADLESS && echo headless || echo gui)"
run sleep 5
stop_if_requested "start"

# ======================================================
section "ip"
# ======================================================
IP=""
PROP=""

# If SSH_NIC explicitly set, wait ONLY for it
if [[ -n "$SSH_NIC" ]]; then
  PROP="/VirtualBox/GuestInfo/Net/$((SSH_NIC-1))/V4/IP"
  echo "Waiting for SSH NIC$SSH_NIC IP via $PROP"

  if $DRY_RUN; then
    echo "DRY-RUN: VBoxManage guestproperty get \"$NEW_VM\" \"$PROP\""
    IP="0.0.0.0"
  else
    # Wait up to 90 seconds for host-only DHCP
    for _ in {1..90}; do
      RAW=$(VBoxManage guestproperty get "$NEW_VM" "$PROP" 2>/dev/null || true)
      VAL=$(awk '{print $2}' <<<"$RAW")
      if [[ "$VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IP="$VAL"
        break
      fi
      sleep 1
    done
  fi

  [[ -z "$IP" ]] && fail "SSH NIC$SSH_NIC did not obtain an IP in time"
else
  # Auto-detect mode (fallback allowed)
  for nic in {1..8}; do
    PROP="/VirtualBox/GuestInfo/Net/$((nic-1))/V4/IP"
    echo "Trying NIC$nic → $PROP"

    if $DRY_RUN; then
      IP="0.0.0.0"
      break
    fi

    for _ in {1..10}; do
      RAW=$(VBoxManage guestproperty get "$NEW_VM" "$PROP" 2>/dev/null || true)
      VAL=$(awk '{print $2}' <<<"$RAW")
      if [[ "$VAL" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        IP="$VAL"
        break 2
      fi
      sleep 1
    done
  done
fi

echo "VM IP: $IP"
stop_if_requested "ip"

# ======================================================
section "ssh"
# ======================================================
run_ssh "sudo hostnamectl set-hostname '$NEW_HOSTNAME'"
stop_if_requested "ssh"

# ======================================================
section "reboot"
# ======================================================
run_ssh "sudo reboot" || true
run sleep 5
stop_if_requested "reboot"

# ======================================================
section "wait"
# ======================================================
wait_for_ssh || fail "SSH did not come back"
stop_if_requested "wait"

# ======================================================
section "debug-tee"
# ======================================================

run_ssh "sudo tee /usr/local/bin/tee-test.sh >/dev/null <<'EOF'
#!/usr/bin/env bash
echo \"TEE TEST OK from \$(hostname)\"
EOF"

run_ssh "sudo chmod +x /usr/local/bin/tee-test.sh"

run_ssh "ls -l /usr/local/bin/tee-test.sh || echo 'tee-test.sh NOT FOUND'"

run_ssh "/usr/local/bin/tee-test.sh || echo 'EXEC FAILED'"

stop_if_requested "debug-tee"

# ======================================================
section "push-github-scripts"
# ======================================================

if $GITHUB_KEY_CREATE; then
  scp scripts/github-ssh-key.sh \
      scripts/github-ssh-key-manage.sh \
      "${SSH_USER}@${IP}:/tmp/"
else
  echo "Skipping GitHub SSH script copy"
fi

stop_if_requested "push-github-scripts"

# ======================================================
section "install-github-tools"
# ======================================================

if $GITHUB_KEY_CREATE; then
  run_ssh "sudo install -m 0755 /tmp/github-ssh-key.sh /usr/local/bin/github-ssh-key"
  run_ssh "sudo install -m 0755 /tmp/github-ssh-key-manage.sh /usr/local/bin/github-ssh-key-manage"
else
  echo "Skipping GitHub SSH tooling installation"
fi

stop_if_requested "install-github-tools"

# ======================================================
section "github-ssh-key"
# ======================================================

if $GITHUB_KEY_CREATE; then
  if $GITHUB_KEY_UPLOAD; then
    run_ssh "sudo -iu ${SSH_USER} github-ssh-key --upload"
  else
    run_ssh "sudo -iu ${SSH_USER} github-ssh-key"
  fi
else
  echo "GitHub SSH key generation disabled"
fi

stop_if_requested "github-ssh-key"

# ======================================================
section "summary"
# ======================================================
echo "VM Name     : $NEW_VM"
echo "Hostname    : $NEW_HOSTNAME"
echo "Snapshot    : $SNAPSHOT"
echo "Config NIC  : $CONFIG_NIC ($NET_MODE)"
echo "SSH NIC     : ${SSH_NIC:-auto}"

print_all_ips "$NEW_VM"

VBoxManage showvminfo "$NEW_VM" --machinereadable \
  | grep -E 'VMState=|nic[0-9]=' || true

echo
echo "Done."
