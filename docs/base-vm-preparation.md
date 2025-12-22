
# Base VM Preparation Guide

This document describes how to prepare an Ubuntu VM so it can be safely used
as the source for VirtualBox linked clones.

## Key Goals
- Unique identity per clone
- Reliable SSH
- Guest Additions installed
- GitHub CLI authenticated once

## Steps Summary
1. Install Ubuntu 22.04 LTS
2. Update system packages
3. Expand disk (LVM if used)
4. Configure secondary NIC (host-only recommended)
5. Install VirtualBox Guest Additions
6. Configure passwordless sudo
7. Reset machine-id (CRITICAL)
8. Install git, gh, openssh-client
9. Authenticate GitHub CLI using device flow
10. Reset machine-id again
11. Power off and snapshot as `base-clean`
