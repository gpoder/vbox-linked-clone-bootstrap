
# vbox-linked-clone-bootstrap

A production-grade Bash workflow for creating **VirtualBox linked clones** from a prepared Ubuntu base VM,
with automated post-clone configuration including networking, SSH availability, reboots, and per-VM GitHub SSH keys.

## Features
- Linked clones (fast + disk-efficient)
- Reboot-safe SSH orchestration
- Strict Bash mode (`set -euo pipefail`)
- Per-VM GitHub SSH keys (no sharing)
- Compatible with older `gh` versions
- Headless-friendly

## Repository Layout
```
.
├── vbox-linked-clone.sh
├── scripts/
│   └── setup-github-ssh.sh
├── docs/
│   └── base-vm-preparation.md
├── .gitignore
└── README.md
```

## Quick Start
1. Prepare a base Ubuntu VM (see docs/base-vm-preparation.md)
2. Snapshot it as `base-clean`
3. Run:
```bash
./vbox-linked-clone.sh --base ubuntu-base --name vm01 --config-nic 1 --network hostonly
```

## Release
Current release: **v3.7**
