# VirtualBox Linked Clone Bootstrapper

This repository contains a **production-grade Bash script** for creating **linked clones** of a prepared Ubuntu VirtualBox VM and performing automated post-clone configuration, including:

- Network configuration
- Hostname changes
- SSH availability checks across reboots
- Per-VM GitHub SSH key generation
- Automatic GitHub SSH key upload using `gh`
- Safe operation under `set -euo pipefail`

The design goal is **fast, reproducible VM creation** with **zero manual steps after cloning**.

---

## Features

- Linked clones for minimal disk usage
- Deterministic SSH availability handling (password → key)
- Reboot-safe automation
- Per-VM GitHub SSH identity (no shared keys)
- Compatible with older `gh` versions
- Idempotent (safe to re-run)
- Designed for headless hosts

---

## Repository Contents

```
.
├── vbox-linked-clone.sh          # Main automation script
├── scripts/
│   └── setup-github-ssh.sh       # Per-VM GitHub SSH bootstrap
├── docs/
│   └── base-vm-preparation.md    # How to prepare the source VM
├── .gitignore
└── README.md
```

---

## Host Machine Prerequisites

On the **VirtualBox host** (not the VM):

- VirtualBox 7.x
- Bash 4+
- OpenSSH client
- `sshpass` (only required if using password bootstrap)
- A user account that can run `VBoxManage`

Verify:

```bash
VBoxManage --version
ssh -V
```

---

## Supported Guest OS

- Ubuntu 22.04 LTS (recommended)
- Other Ubuntu flavours should work with minimal adjustment

---

## Preparing the Source (Base) VM

This is the **most important part** of the process.

The base VM must be carefully prepared so that:
- Linked clones do not share identity
- Networking works reliably
- SSH works non-interactively
- GitHub authentication can be inherited safely

Below is a **clean, ordered procedure** distilled from real-world setup history.

---

### 1. Install Ubuntu

- Create a new VM in VirtualBox
- Install Ubuntu normally
- Create a user (e.g. `ziggy`)
- Enable OpenSSH Server during install (or install later)

---

### 2. Update the System

```bash
sudo apt update
sudo apt upgrade -y
sudo reboot
```

---

### 3. Expand Disk (if using LVM)

Check layout:

```bash
df -h
sudo fdisk -l
sudo vgs
```

Extend logical volume to fill disk:

```bash
sudo lvextend -l +100%FREE /dev/ubuntu-vg/ubuntu-lv
sudo resize2fs /dev/ubuntu-vg/ubuntu-lv
df -h
```

Shutdown after resize:

```bash
sudo poweroff
```

---

### 4. Configure Networking (Secondary NIC)

Bring up the secondary NIC (example: `enp0s8`):

```bash
sudo ip link set enp0s8 up
ip a
```

Create Netplan config:

```bash
sudo nano /etc/netplan/02-enp0s8.yaml
```

Example:

```yaml
network:
  version: 2
  ethernets:
    enp0s8:
      dhcp4: true
```

Apply:

```bash
sudo netplan apply
ip a
```

---

### 5. Install VirtualBox Guest Additions

Insert Guest Additions CD from the VirtualBox menu.

```bash
sudo apt install -y gcc make perl bzip2
sudo mount /dev/cdrom /mnt
cd /mnt
sudo ./VBoxLinuxAdditions.run
sudo reboot
```

Verify:

```bash
systemctl status vboxadd-service
```

---

### 6. Configure Passwordless sudo

Edit sudoers:

```bash
sudo visudo
```

Add:

```text
ziggy ALL=(ALL) NOPASSWD:ALL
```

---

### 7. Reset Machine Identity (CRITICAL)

This ensures **each clone gets a unique identity**.

```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
```

Verify empty:

```bash
sudo hexdump -C /etc/machine-id
```

Power off after this step:

```bash
sudo poweroff
```

---

### 8. Install GitHub CLI and SSH Tools

```bash
sudo apt update
sudo apt install -y gh git openssh-client
gh --version
```

---

### 9. One-Time GitHub Authentication (Device Flow)

Run **once on the base VM**:

```bash
gh auth login
```

Choose:
- GitHub.com
- SSH
- Login with a web browser

Complete the device login on another machine.

Verify:

```bash
gh auth status
```

⚠️ **Do not log out after this** — credentials are inherited by clones.

---

### 10. Final Machine-ID Reset (Recommended)

This ensures clones regenerate identity *after* GitHub auth is cached.

```bash
sudo truncate -s 0 /etc/machine-id
sudo rm -f /var/lib/dbus/machine-id
sudo ln -s /etc/machine-id /var/lib/dbus/machine-id
sudo poweroff
```

---

### 11. Create the Base Snapshot

On the host:

```bash
VBoxManage snapshot "SOURCE_VM_NAME" take base-clean
```

This snapshot is what all linked clones will use.

---

## Using the Script

### Example

```bash
./vbox-linked-clone.sh \
  --base ubuntu-base \
  --name newvm01 \
  --config-nic 1 \
  --network hostonly \
  --use-sshpass \
  --user ziggy \
  --pass cookie
```

---

### What Happens Automatically

- Linked clone is created
- MAC addresses regenerated
- VM started
- IP discovered via Guest Additions
- Hostname updated
- VM rebooted
- SSH availability verified
- GitHub SSH key generated **per VM**
- SSH key uploaded to GitHub
- GitHub host key pre-seeded
- Summary printed

---

## GitHub SSH Behaviour

Each clone gets:

```text
~/.ssh/id_github_<hostname>
```

Uploaded to GitHub as:

```text
<hostname>
```

No keys are shared between VMs.

---

## Why This Script Exists

This script solves real-world problems that appear when you combine:

- Linked clones
- Strict Bash (`set -euo pipefail`)
- SSH across reboots
- GitHub CLI automation
- Non-interactive environments

It intentionally avoids cloud-init, Packer, or Ansible to remain **portable and inspectable**.

---

## Known Assumptions

- GitHub CLI auth is done once on the base VM
- Clones trust GitHub’s SSH host key
- You control the VirtualBox host
- Home-lab or trusted environment

---

## License

MIT (recommended) or your choice.
