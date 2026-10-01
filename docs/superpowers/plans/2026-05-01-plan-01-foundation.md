# PrivacyPi — Plan 1: Foundation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Flash Ubuntu Server 24.04 LTS onto the Raspberry Pi 4B and harden the OS so it is ready to host the PrivacyPi privacy services. End state: an SSH-accessible, security-patched, sandboxed Pi with AppArmor, CrowdSec, unattended-upgrades, auditd, and a hardware watchdog all running and verified.

**Architecture:** All Pi system configuration files are mirrored under `system/etc/` in this repo so they are version-controlled. A deployment script (`scripts/deploy-foundation.sh`) rsyncs config files to the Pi and applies them. A verification script (`scripts/verify-foundation.sh`) confirms each hardening control is active. SSH access is via Ethernet (`eth0`) for the duration of this plan; WiFi-only operation comes in Plan 2.

**Tech Stack:** Ubuntu Server 24.04 LTS, AppArmor, unattended-upgrades, CrowdSec, OpenSSH, auditd, systemd, bcm2835_wdt (hardware watchdog), bash deployment scripts.

---

## Prerequisites

Before starting this plan, the human operator must have:
- A microSD card (16 GB or larger, Class 10+)
- Raspberry Pi Imager installed on their Mac (https://www.raspberrypi.com/software/)
- The Raspberry Pi 4B physically accessible
- An Ethernet cable connecting the Pi to the home router
- The home router admin panel accessible (to find the Pi's IP after boot)
- A SSH client on the Mac (built in: `ssh`)
- Network connectivity from the Mac to the Pi over Ethernet

---

## File Structure

Files this plan creates or modifies:

```
/Users/mogli/Desktop/VPN/
├── system/
│   └── etc/
│       ├── apt/
│       │   └── apt.conf.d/
│       │       ├── 50unattended-upgrades       ← Pi config
│       │       └── 20auto-upgrades              ← Pi config
│       ├── ssh/
│       │   └── sshd_config.d/
│       │       └── 10-privacypi.conf            ← SSH hardening
│       ├── sysctl.d/
│       │   └── 99-privacypi.conf                ← Kernel sysctls
│       ├── modules-load.d/
│       │   └── privacypi.conf                   ← Kernel modules
│       ├── audit/
│       │   └── rules.d/
│       │       └── privacypi.rules              ← Audit rules
│       ├── systemd/
│       │   └── system.conf.d/
│       │       └── 10-privacypi-watchdog.conf   ← Watchdog
│       └── privacypi/
│           └── README.md                        ← Service config root marker
├── scripts/
│   ├── deploy-foundation.sh                     ← Main deployment script
│   ├── verify-foundation.sh                     ← System verification
│   └── lib/
│       └── ssh-helpers.sh                       ← SSH helper functions
├── docs/
│   └── ops/
│       └── plan-01-runbook.md                   ← Manual flash + first boot guide
└── .gitignore                                   ← exclude secrets, tmp files
```

---

## Conventions for All Tasks

- **Pi user:** `privacypi` (created in Task 4). Steps before that use `ubuntu` (Ubuntu's default).
- **Pi IP:** Discovered in Task 2 and stored in `~/.privacypi-host` on the Mac for reuse.
- **SSH command shorthand:** `ssh privacypi@$(cat ~/.privacypi-host)` (or `ubuntu@...` pre-Task 4).
- **All config files** are written first to the local repo under `system/`, committed, then deployed via rsync.
- **Each task ends with a commit** capturing the local file changes and tracker updates.
- **Verification before progress:** Every task has a verify step. Do not advance if a verify step fails.

---

## Task 1: Operations Runbook for Flashing & First Boot

**Files:**
- Create: `/Users/mogli/Desktop/VPN/docs/ops/plan-01-runbook.md`

This task produces a written runbook the human operator follows to physically flash the SD card and boot the Pi. The Pi cannot be flashed by code — this is operator-driven.

- [ ] **Step 1: Create the docs/ops directory**

```bash
mkdir -p /Users/mogli/Desktop/VPN/docs/ops
```

- [ ] **Step 2: Write the runbook**

Create `/Users/mogli/Desktop/VPN/docs/ops/plan-01-runbook.md` with this exact content:

````markdown
# Plan 1 Runbook — Flash & First Boot

## Step A: Download Ubuntu Server 24.04 LTS

> If Raspberry Pi Imager is not installed, download it from https://www.raspberrypi.com/software/ and install it first.

1. Open Raspberry Pi Imager.
2. Click "CHOOSE OS" → "Other general-purpose OS" → "Ubuntu" → **"Ubuntu Server 24.04.x LTS (64-bit)"**.
3. Click "CHOOSE STORAGE" → select your microSD card.
4. Open Advanced Options to configure first-boot settings:
   - In Imager **1.7 and earlier**, click the gear icon (⚙).
   - In Imager **1.8 and later**, click NEXT, then "EDIT SETTINGS" when the OS Customization dialog appears.

   Configure:
   - **Hostname:** `privacypi`
   - **Enable SSH:** ✓ checked, "Use password authentication"
   - **Username:** `ubuntu`
   - **Password:** pick a strong temporary password (we change this in Task 4)
   - **Configure wireless LAN:** leave unchecked (we use Ethernet for Plan 1)
   - **Set locale settings:** your timezone and keyboard layout
5. Click "SAVE", then "WRITE" (or "YES, APPLY OS CUSTOMIZATION SETTINGS" then "YES" on newer Imager). Confirm the overwrite warning.
6. Wait for "Write Successful". Eject the card.

## Step B: First Boot

1. Insert the microSD card into the Pi 4B.
2. Plug Ethernet from the Pi to your home router.
3. Plug in power. Wait 90 seconds for first boot to complete (cloud-init runs on first boot).
4. Find the Pi's IP address (try the options in order — the first one that works is fine):
   - **Option 1:** Open your home router admin panel → DHCP client list → look for `privacypi` or a Raspberry Pi Foundation MAC OUI.
   - **Option 2:** Run on Mac: `arp -a | grep -i 'b8:27:eb\|dc:a6:32\|e4:5f:01\|d8:3a:dd'` (Pi MAC prefixes).
   - **Option 3:** Run on Mac: `dns-sd -q privacypi.local` and wait for an answer. *(This command does not exit on its own — press Ctrl-C after about 10 seconds, whether or not an answer appeared.)*

## Step C: Save the Pi IP for Reuse

On the Mac, save the IP found in Step B for later steps. **Replace `<PI_IP_HERE>` with the actual IP address (e.g., `192.168.1.42`) — do not include the angle brackets.**

```bash
echo "<PI_IP_HERE>" > ~/.privacypi-host
```

Verify the file contains a real IP, not the literal placeholder:

```bash
cat ~/.privacypi-host
```

Expected: a single IPv4 address like `192.168.1.42`. If you see `<PI_IP_HERE>` instead, redo this step with the actual address.

## Step D: First SSH

```bash
ssh ubuntu@$(cat ~/.privacypi-host)
```

You will see a prompt like:

```
The authenticity of host '192.168.1.42 (192.168.1.42)' can't be established.
ED25519 key fingerprint is SHA256:...
Are you sure you want to continue connecting (yes/no/[fingerprint])?
```

Type `yes` and press Enter. Then enter the temporary password set in Step A.

You should see the Ubuntu login banner. Type `exit` to disconnect.

## Done

When all of A through D succeed, return to the implementation plan and proceed to Task 2.
````

- [ ] **Step 3: Verify the file**

Run on Mac:

```bash
test -s /Users/mogli/Desktop/VPN/docs/ops/plan-01-runbook.md && echo OK
```

Expected output: `OK`

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add docs/ops/plan-01-runbook.md
git commit -m "docs(plan-01): runbook for SD flash and first boot"
```

- [ ] **Step 5: HUMAN ACTION — Execute the runbook**

The operator now flashes the SD card and boots the Pi following `docs/ops/plan-01-runbook.md` Step A through D. After Step D succeeds, `~/.privacypi-host` exists and contains the Pi's IP.

Verify on Mac:

```bash
test -s ~/.privacypi-host && cat ~/.privacypi-host
```

Expected output: a single IPv4 address (e.g., `192.168.1.42`).

If this fails, the Pi did not boot or is not reachable. Stop and resolve before continuing.

---

## Task 2: SSH Helper Library

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/lib/ssh-helpers.sh`

A small bash library that subsequent scripts source. It centralizes SSH and rsync calls and reads the Pi IP from `~/.privacypi-host`.

- [ ] **Step 1: Write the helper library**

Create `/Users/mogli/Desktop/VPN/scripts/lib/ssh-helpers.sh`:

```bash
#!/usr/bin/env bash
# SSH and rsync helpers for PrivacyPi deployment.
# Reads the Pi IP from ~/.privacypi-host.

set -euo pipefail

PI_HOST_FILE="$HOME/.privacypi-host"
if [[ ! -s "$PI_HOST_FILE" ]]; then
  echo "ERROR: $PI_HOST_FILE missing or empty. Run the runbook first." >&2
  exit 1
fi
PI_HOST="$(tr -d '[:space:]' < "$PI_HOST_FILE")"

# Default user is overridden via PI_USER env var. Until Task 4 the user is 'ubuntu'.
PI_USER="${PI_USER:-ubuntu}"

# pi_ssh "<command>"
pi_ssh() {
  ssh -o StrictHostKeyChecking=accept-new "${PI_USER}@${PI_HOST}" "$@"
}

# pi_scp <local> <remote>
pi_scp() {
  scp -o StrictHostKeyChecking=accept-new "$1" "${PI_USER}@${PI_HOST}:$2"
}

# pi_rsync <local_dir_or_file> <remote_path>
pi_rsync() {
  rsync -avz --rsync-path="sudo rsync" -e "ssh -o StrictHostKeyChecking=accept-new" "$1" "${PI_USER}@${PI_HOST}:$2"
}

# pi_sudo "<command>"
pi_sudo() {
  pi_ssh "sudo bash -c '$*'"
}
```

- [ ] **Step 2: Make it executable and verify syntax**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/lib/ssh-helpers.sh
bash -n scripts/lib/ssh-helpers.sh && echo "Syntax OK"
```

Expected output: `Syntax OK`

- [ ] **Step 3: Smoke-test it**

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'echo "hello from $(hostname)"' )
```

Expected output: `hello from privacypi`

If this fails: SSH is not reachable. Stop and resolve.

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/lib/ssh-helpers.sh
git commit -m "feat(scripts): add SSH/rsync helper library"
```

---

## Task 3: Initial System Update

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/00-system-update.sh`

Apply pending updates to the freshly-flashed Pi.

- [ ] **Step 1: Write the update script**

Create `/Users/mogli/Desktop/VPN/scripts/00-system-update.sh`:

```bash
#!/usr/bin/env bash
# Apply all pending package updates on the Pi.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Updating apt indexes"
pi_ssh 'sudo apt-get update -y'

echo "==> Upgrading installed packages"
pi_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get upgrade -y'

echo "==> Auto-removing orphaned packages"
pi_ssh 'sudo apt-get autoremove -y'

echo "==> Done"
```

- [ ] **Step 2: Make executable**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/00-system-update.sh
bash -n scripts/00-system-update.sh && echo "Syntax OK"
```

Expected output: `Syntax OK`

- [ ] **Step 3: Run it**

```bash
cd /Users/mogli/Desktop/VPN
./scripts/00-system-update.sh
```

Expected: Output ends with `==> Done` and no error lines.

- [ ] **Step 4: Verify the kernel is current**

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'uname -a' )
```

Expected: Reports a 6.x kernel for Ubuntu 24.04. If a kernel was upgraded during step 3, reboot the Pi:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'sudo reboot' ) || true
echo "Waiting 60s for reboot..."
sleep 60
( source scripts/lib/ssh-helpers.sh && pi_ssh 'uptime' )
```

- [ ] **Step 5: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/00-system-update.sh
git commit -m "feat(scripts): system update bootstrap"
```

---

## Task 4: Create the `privacypi` User

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/01-create-user.sh`

Create the dedicated `privacypi` user, copy the operator's SSH public key for key-based auth, and grant sudo. Keep the `ubuntu` user enabled for now as a fallback (we disable later).

- [ ] **Step 1: Ensure the operator has an SSH key**

```bash
test -f ~/.ssh/id_ed25519.pub || test -f ~/.ssh/id_rsa.pub
```

Expected exit code: `0`. If neither exists, generate one:

```bash
ssh-keygen -t ed25519 -C "privacypi-admin" -f ~/.ssh/id_ed25519 -N ""
```

- [ ] **Step 2: Write the user-creation script**

Create `/Users/mogli/Desktop/VPN/scripts/01-create-user.sh`:

```bash
#!/usr/bin/env bash
# Create the 'privacypi' user, copy SSH key, grant sudo.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PUBKEY_FILE=""
for candidate in "$HOME/.ssh/id_ed25519.pub" "$HOME/.ssh/id_rsa.pub"; do
  if [[ -f "$candidate" ]]; then PUBKEY_FILE="$candidate"; break; fi
done
if [[ -z "$PUBKEY_FILE" ]]; then
  echo "ERROR: no SSH public key found in ~/.ssh/" >&2
  exit 1
fi
PUBKEY="$(cat "$PUBKEY_FILE")"

echo "==> Creating user 'privacypi' if not exists"
pi_ssh "id privacypi >/dev/null 2>&1 || sudo useradd -m -s /bin/bash -G sudo privacypi"

echo "==> Setting up SSH key for privacypi"
pi_ssh "sudo install -d -m 700 -o privacypi -g privacypi /home/privacypi/.ssh"
pi_ssh "echo '$PUBKEY' | sudo tee /home/privacypi/.ssh/authorized_keys >/dev/null"
pi_ssh "sudo chown privacypi:privacypi /home/privacypi/.ssh/authorized_keys && sudo chmod 600 /home/privacypi/.ssh/authorized_keys"

echo "==> Granting passwordless sudo (temporary, narrowed in later plans)"
pi_ssh "echo 'privacypi ALL=(ALL) NOPASSWD:ALL' | sudo tee /etc/sudoers.d/10-privacypi-temp >/dev/null"
pi_ssh "sudo chmod 440 /etc/sudoers.d/10-privacypi-temp"

echo "==> Done"
```

- [ ] **Step 3: Make executable & run**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/01-create-user.sh
bash -n scripts/01-create-user.sh && echo "Syntax OK"
./scripts/01-create-user.sh
```

Expected: Output ends with `==> Done`.

- [ ] **Step 4: Verify SSH-as-privacypi works (key-based)**

```bash
cd /Users/mogli/Desktop/VPN
PI_USER=privacypi bash -c 'source scripts/lib/ssh-helpers.sh && pi_ssh "whoami && hostname"'
```

Expected output:
```
privacypi
privacypi
```

- [ ] **Step 5: Switch the helper default user to `privacypi`**

```bash
cd /Users/mogli/Desktop/VPN
sed -i '' 's/^PI_USER="\${PI_USER:-ubuntu}"/PI_USER="${PI_USER:-privacypi}"/' scripts/lib/ssh-helpers.sh
bash -n scripts/lib/ssh-helpers.sh && echo "Syntax OK"
( source scripts/lib/ssh-helpers.sh && pi_ssh 'whoami' )
```

Expected output: `privacypi`

- [ ] **Step 6: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/01-create-user.sh scripts/lib/ssh-helpers.sh
git commit -m "feat(scripts): create privacypi user with key-based SSH"
```

---

## Task 5: Install Base Packages

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/02-base-packages.sh`

Install everything needed for the rest of the plan and for Plan 2 networking.

- [ ] **Step 1: Write the base packages script**

Create `/Users/mogli/Desktop/VPN/scripts/02-base-packages.sh`:

```bash
#!/usr/bin/env bash
# Install base packages required by the foundation and Plan 2.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PACKAGES=(
  # Core tooling
  git curl wget jq unzip ca-certificates gnupg lsb-release
  # Python (Flask app comes in a later plan)
  python3 python3-pip python3-venv python3-dev
  # Networking
  iproute2 iptables iptables-persistent ipset bridge-utils vlan
  net-tools tcpdump dnsutils ethtool wireless-tools iw
  # System utilities
  sqlite3 rsync htop nano vim
  # Build essentials (some privacy services need to compile)
  build-essential pkg-config libssl-dev
  # Hardening prerequisites (full install in later tasks)
  apparmor apparmor-utils apparmor-profiles
  unattended-upgrades
  auditd audispd-plugins
  watchdog
)

echo "==> apt update"
pi_ssh 'sudo apt-get update -y'

echo "==> Installing ${#PACKAGES[@]} packages"
pi_ssh "sudo DEBIAN_FRONTEND=noninteractive apt-get install -y ${PACKAGES[*]}"

echo "==> Done"
```

- [ ] **Step 2: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/02-base-packages.sh
bash -n scripts/02-base-packages.sh && echo "Syntax OK"
./scripts/02-base-packages.sh
```

Expected: Ends with `==> Done`.

- [ ] **Step 3: Spot-check installations**

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'python3 --version && iptables --version | head -1 && aa-status --version 2>&1 | head -1 && which auditctl && which crowdsec || echo crowdsec_not_yet' )
```

Expected: Python 3.12.x, iptables version line, AppArmor version line, `/usr/sbin/auditctl`, and `crowdsec_not_yet` (CrowdSec installed in Task 11).

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/02-base-packages.sh
git commit -m "feat(scripts): install base packages"
```

---

## Task 6: Kernel Modules & Sysctl Tuning

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/modules-load.d/privacypi.conf`
- Create: `/Users/mogli/Desktop/VPN/system/etc/sysctl.d/99-privacypi.conf`
- Create: `/Users/mogli/Desktop/VPN/scripts/03-kernel-tuning.sh`

Load the kernel modules required for VLAN-tagged AP and bridging, and set sysctls to enable IP forwarding and lock down the kernel.

- [ ] **Step 1: Write the modules-load file**

Create `/Users/mogli/Desktop/VPN/system/etc/modules-load.d/privacypi.conf`:

```text
# Loaded at boot. Required for VLAN-aware AP and bridging.
8021q
br_netfilter
```

- [ ] **Step 2: Write the sysctl file**

Create `/Users/mogli/Desktop/VPN/system/etc/sysctl.d/99-privacypi.conf`:

```text
# Enable IP forwarding (router role)
net.ipv4.ip_forward=1
net.ipv6.conf.all.forwarding=1

# Reverse-path filter (anti-spoofing)
net.ipv4.conf.all.rp_filter=1
net.ipv4.conf.default.rp_filter=1

# Drop source-routed packets
net.ipv4.conf.all.accept_source_route=0
net.ipv6.conf.all.accept_source_route=0

# Ignore ICMP redirects
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
net.ipv6.conf.all.accept_redirects=0

# Don't send ICMP redirects (we are a router but not multi-homed in the legacy sense)
net.ipv4.conf.all.send_redirects=0
net.ipv4.conf.default.send_redirects=0

# Log martians
net.ipv4.conf.all.log_martians=1

# TCP SYN flood protection
net.ipv4.tcp_syncookies=1

# Disable IPv6 Router Advertisements (we manage IPv6 per VLAN later)
net.ipv6.conf.all.accept_ra=0
net.ipv6.conf.default.accept_ra=0

# Use bridge-netfilter (required for iptables on bridged traffic)
net.bridge.bridge-nf-call-iptables=1
net.bridge.bridge-nf-call-ip6tables=1
```

- [ ] **Step 3: Write the deploy script**

Create `/Users/mogli/Desktop/VPN/scripts/03-kernel-tuning.sh`:

```bash
#!/usr/bin/env bash
# Deploy kernel modules + sysctl tuning to the Pi.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Pushing modules-load file"
pi_rsync "$REPO_ROOT/system/etc/modules-load.d/privacypi.conf" \
         /etc/modules-load.d/privacypi.conf

echo "==> Pushing sysctl file"
pi_rsync "$REPO_ROOT/system/etc/sysctl.d/99-privacypi.conf" \
         /etc/sysctl.d/99-privacypi.conf

echo "==> Loading modules now"
pi_ssh 'sudo modprobe 8021q && sudo modprobe br_netfilter'

echo "==> Applying sysctl values now"
pi_ssh 'sudo sysctl --system | grep -E "(forward|rp_filter|tcp_syncookies|bridge-nf|martians)" || true'

echo "==> Done"
```

- [ ] **Step 4: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/03-kernel-tuning.sh
bash -n scripts/03-kernel-tuning.sh && echo "Syntax OK"
./scripts/03-kernel-tuning.sh
```

Then verify state on the Pi:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh '
  lsmod | grep -E "^(8021q|br_netfilter)" &&
  sysctl net.ipv4.ip_forward net.ipv4.conf.all.rp_filter net.ipv4.tcp_syncookies
' )
```

Expected: Both modules listed, all three sysctls = `1`.

- [ ] **Step 5: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/modules-load.d/privacypi.conf system/etc/sysctl.d/99-privacypi.conf scripts/03-kernel-tuning.sh
git commit -m "feat(kernel): load 8021q + br_netfilter, harden sysctls"
```

---

## Task 7: Disable systemd-resolved

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/04-disable-resolved.sh`

`systemd-resolved` listens on port 53 by default. PrivacyPi's AdGuard Home will own port 53. Disable resolved cleanly so this is permanent.

- [ ] **Step 1: Write the script**

Create `/Users/mogli/Desktop/VPN/scripts/04-disable-resolved.sh`:

```bash
#!/usr/bin/env bash
# Disable systemd-resolved so port 53 is free for AdGuard Home.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Stopping and disabling systemd-resolved"
pi_ssh 'sudo systemctl disable --now systemd-resolved.service'

echo "==> Replacing /etc/resolv.conf with a static fallback (Cloudflare for now)"
pi_ssh 'sudo rm -f /etc/resolv.conf'
pi_ssh 'echo -e "nameserver 1.1.1.1\nnameserver 9.9.9.9\n" | sudo tee /etc/resolv.conf >/dev/null'

# Make resolv.conf immutable so DHCP cannot rewrite it; later plans manage it.
pi_ssh 'sudo chattr +i /etc/resolv.conf'

echo "==> Done"
```

- [ ] **Step 2: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/04-disable-resolved.sh
bash -n scripts/04-disable-resolved.sh && echo "Syntax OK"
./scripts/04-disable-resolved.sh
```

Verify nothing listens on port 53:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh '
  systemctl is-active systemd-resolved.service || true
  sudo ss -tulnp | grep ":53 " || echo "port 53 free"
' )
```

Expected: First line: `inactive`. Second line: `port 53 free`.

- [ ] **Step 3: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/04-disable-resolved.sh
git commit -m "feat(dns): disable systemd-resolved, free port 53"
```

---

## Task 8: PrivacyPi Directory Structure

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/privacypi/README.md`
- Create: `/Users/mogli/Desktop/VPN/scripts/05-create-dirs.sh`

Create the canonical directory layout on the Pi for service configs, app, logs, and database, with correct ownership.

- [ ] **Step 1: Write the placeholder README**

Create `/Users/mogli/Desktop/VPN/system/etc/privacypi/README.md`:

```markdown
# /etc/privacypi/

Service configuration root for PrivacyPi.

Subdirectories are created and managed by Plans 2-12 of the implementation
(VPN configs, Tor config, AP config, etc.). Files in this tree are written
by the Flask app via the sudoers-whitelisted scripts in /opt/privacypi/scripts/.
```

- [ ] **Step 2: Write the directory creation script**

Create `/Users/mogli/Desktop/VPN/scripts/05-create-dirs.sh`:

```bash
#!/usr/bin/env bash
# Create canonical PrivacyPi directories on the Pi.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

DIRS=(
  /opt/privacypi
  /opt/privacypi/scripts
  /etc/privacypi
  /var/lib/privacypi
  /var/log/privacypi
)

echo "==> Creating directories"
for d in "${DIRS[@]}"; do
  pi_ssh "sudo install -d -m 750 -o privacypi -g privacypi $d"
done

echo "==> Pushing /etc/privacypi/README.md placeholder"
pi_rsync "$REPO_ROOT/system/etc/privacypi/README.md" \
         /etc/privacypi/README.md

echo "==> Done"
```

- [ ] **Step 3: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/05-create-dirs.sh
bash -n scripts/05-create-dirs.sh && echo "Syntax OK"
./scripts/05-create-dirs.sh

( source scripts/lib/ssh-helpers.sh && pi_ssh '
  for d in /opt/privacypi /opt/privacypi/scripts /etc/privacypi /var/lib/privacypi /var/log/privacypi; do
    stat -c "%n %U:%G %a" $d
  done
' )
```

Expected: All five directories listed, each owned `privacypi:privacypi`, mode `750`.

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/privacypi/README.md scripts/05-create-dirs.sh
git commit -m "feat(fs): create PrivacyPi canonical directory layout"
```

---

## Task 9: Enable AppArmor Enforcing

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/06-apparmor.sh`

AppArmor was installed in Task 5. Confirm it's enforcing for all stock profiles. Per-service AppArmor policies for privacy daemons are added in their respective plans.

- [ ] **Step 1: Write the script**

Create `/Users/mogli/Desktop/VPN/scripts/06-apparmor.sh`:

```bash
#!/usr/bin/env bash
# Enable AppArmor and verify it is enforcing.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Ensure AppArmor service enabled and started"
pi_ssh 'sudo systemctl enable --now apparmor.service'

echo "==> Reload all profiles"
pi_ssh 'sudo aa-enforce /etc/apparmor.d/* 2>/dev/null || true'

echo "==> Status"
pi_ssh 'sudo aa-status'

echo "==> Done"
```

- [ ] **Step 2: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/06-apparmor.sh
bash -n scripts/06-apparmor.sh && echo "Syntax OK"
./scripts/06-apparmor.sh
```

Verify enforcing:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh '
  sudo aa-status | grep -E "profiles are loaded|profiles are in enforce"
' )
```

Expected: Two lines, both with non-zero counts of profiles.

- [ ] **Step 3: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/06-apparmor.sh
git commit -m "feat(security): enable AppArmor enforcing"
```

---

## Task 10: Configure unattended-upgrades

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/apt/apt.conf.d/50unattended-upgrades`
- Create: `/Users/mogli/Desktop/VPN/system/etc/apt/apt.conf.d/20auto-upgrades`
- Create: `/Users/mogli/Desktop/VPN/scripts/07-unattended-upgrades.sh`

Configure automatic security-only upgrades that run daily.

- [ ] **Step 1: Write the upgrade-policy file**

Create `/Users/mogli/Desktop/VPN/system/etc/apt/apt.conf.d/50unattended-upgrades`:

```text
// Security-only unattended upgrades for PrivacyPi.

Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};

// Don't auto-upgrade kernel (require explicit reboot)
Unattended-Upgrade::Package-Blacklist {
    "linux-image-*";
    "linux-headers-*";
};

Unattended-Upgrade::Remove-Unused-Kernel-Packages "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Mail "";
Unattended-Upgrade::SyslogEnable "true";
Unattended-Upgrade::SyslogFacility "daemon";
Unattended-Upgrade::OnlyOnACPower "false";
Unattended-Upgrade::Skip-Updates-On-Metered-Connections "false";
Unattended-Upgrade::Verbose "false";
Unattended-Upgrade::Debug "false";
```

- [ ] **Step 2: Write the auto-upgrades enabler**

Create `/Users/mogli/Desktop/VPN/system/etc/apt/apt.conf.d/20auto-upgrades`:

```text
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
```

- [ ] **Step 3: Write the deploy script**

Create `/Users/mogli/Desktop/VPN/scripts/07-unattended-upgrades.sh`:

```bash
#!/usr/bin/env bash
# Deploy unattended-upgrades configuration.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Pushing 50unattended-upgrades"
pi_rsync "$REPO_ROOT/system/etc/apt/apt.conf.d/50unattended-upgrades" \
         /etc/apt/apt.conf.d/50unattended-upgrades

echo "==> Pushing 20auto-upgrades"
pi_rsync "$REPO_ROOT/system/etc/apt/apt.conf.d/20auto-upgrades" \
         /etc/apt/apt.conf.d/20auto-upgrades

echo "==> Enable timer"
pi_ssh 'sudo systemctl enable --now apt-daily.timer apt-daily-upgrade.timer unattended-upgrades.service'

echo "==> Dry-run test"
pi_ssh 'sudo unattended-upgrade --dry-run --debug 2>&1 | tail -20'

echo "==> Done"
```

- [ ] **Step 4: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/07-unattended-upgrades.sh
bash -n scripts/07-unattended-upgrades.sh && echo "Syntax OK"
./scripts/07-unattended-upgrades.sh

( source scripts/lib/ssh-helpers.sh && pi_ssh '
  systemctl is-enabled apt-daily.timer apt-daily-upgrade.timer
' )
```

Expected: Both timers report `enabled`.

- [ ] **Step 5: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/apt/apt.conf.d/50unattended-upgrades system/etc/apt/apt.conf.d/20auto-upgrades scripts/07-unattended-upgrades.sh
git commit -m "feat(security): configure unattended-upgrades for security patches"
```

---

## Task 11: Install CrowdSec

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/08-crowdsec.sh`

CrowdSec for brute-force/scan detection plus the iptables bouncer for active blocking. Flask bouncer comes in Plan 7.

- [ ] **Step 1: Write the script**

Create `/Users/mogli/Desktop/VPN/scripts/08-crowdsec.sh`:

```bash
#!/usr/bin/env bash
# Install CrowdSec + iptables bouncer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Adding CrowdSec apt repo"
pi_ssh 'curl -fsSL https://install.crowdsec.net | sudo bash'

echo "==> Installing CrowdSec"
pi_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec'

echo "==> Installing iptables bouncer"
pi_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y crowdsec-firewall-bouncer-iptables'

echo "==> Installing common collections"
pi_ssh 'sudo cscli collections install crowdsecurity/linux crowdsecurity/sshd crowdsecurity/iptables'

echo "==> Reload"
pi_ssh 'sudo systemctl restart crowdsec'
pi_ssh 'sudo systemctl restart crowdsec-firewall-bouncer'

echo "==> Status"
pi_ssh 'sudo cscli metrics | head -50 || true'
pi_ssh 'sudo cscli decisions list || true'

echo "==> Done"
```

- [ ] **Step 2: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/08-crowdsec.sh
bash -n scripts/08-crowdsec.sh && echo "Syntax OK"
./scripts/08-crowdsec.sh

( source scripts/lib/ssh-helpers.sh && pi_ssh '
  systemctl is-active crowdsec crowdsec-firewall-bouncer
' )
```

Expected: Both report `active`.

- [ ] **Step 3: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/08-crowdsec.sh
git commit -m "feat(security): install CrowdSec + iptables bouncer"
```

---

## Task 12: SSH Hardening

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/ssh/sshd_config.d/10-privacypi.conf`
- Create: `/Users/mogli/Desktop/VPN/scripts/09-ssh-harden.sh`

Move SSH to key-only auth, disable root login, lock down ciphers. We keep `ubuntu` user for emergency password fallback for now (we wipe it in a later plan).

- [ ] **Step 1: Write the SSH config drop-in**

Create `/Users/mogli/Desktop/VPN/system/etc/ssh/sshd_config.d/10-privacypi.conf`:

```text
# PrivacyPi SSH hardening overrides.

# Authentication
PermitRootLogin no
PasswordAuthentication no
ChallengeResponseAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey

# Limit users
AllowUsers privacypi ubuntu

# Reduce attack surface
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitTunnel no
GatewayPorts no
PrintMotd no

# Session
ClientAliveInterval 300
ClientAliveCountMax 2
LoginGraceTime 30
MaxAuthTries 3
MaxSessions 3

# Strong crypto only
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512,diffie-hellman-group18-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
```

- [ ] **Step 2: Write the deploy script**

Create `/Users/mogli/Desktop/VPN/scripts/09-ssh-harden.sh`:

```bash
#!/usr/bin/env bash
# Harden SSH: key-only auth, no root, strong crypto.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Confirming key-based auth currently works"
pi_ssh 'whoami' >/dev/null
echo "    OK: SSH-as-privacypi confirmed"

echo "==> Pushing SSH drop-in config"
pi_rsync "$REPO_ROOT/system/etc/ssh/sshd_config.d/10-privacypi.conf" \
         /etc/ssh/sshd_config.d/10-privacypi.conf

echo "==> Validating sshd config"
pi_ssh 'sudo sshd -t'

echo "==> Reloading sshd"
pi_ssh 'sudo systemctl reload ssh'

echo "==> Done. Test re-login from a NEW terminal before continuing."
```

- [ ] **Step 3: Run, then verify in a new terminal**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/09-ssh-harden.sh
bash -n scripts/09-ssh-harden.sh && echo "Syntax OK"
./scripts/09-ssh-harden.sh
```

In a **new terminal window** (so the existing SSH connection isn't reused):

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'echo "fresh login OK"' )
```

Expected: `fresh login OK`. If this fails, the old session is still open — fix sshd config there before disconnecting.

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/ssh/sshd_config.d/10-privacypi.conf scripts/09-ssh-harden.sh
git commit -m "feat(security): SSH hardening (key-only, strong crypto)"
```

---

## Task 13: Configure auditd

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/audit/rules.d/privacypi.rules`
- Create: `/Users/mogli/Desktop/VPN/scripts/10-auditd.sh`

Audit the privacy-critical files for tamper detection.

- [ ] **Step 1: Write the audit rules**

Create `/Users/mogli/Desktop/VPN/system/etc/audit/rules.d/privacypi.rules`:

```text
# PrivacyPi audit rules — tamper detection on critical config.

# Self-protect the audit configuration
-w /etc/audit/ -p wa -k auditconfig
-w /etc/audit/rules.d/ -p wa -k auditconfig
-w /var/log/audit/ -p wa -k auditlog

# SSH and sudo
-w /etc/ssh/sshd_config -p wa -k sshd
-w /etc/ssh/sshd_config.d/ -p wa -k sshd
-w /etc/sudoers -p wa -k sudoers
-w /etc/sudoers.d/ -p wa -k sudoers

# User & auth db
-w /etc/passwd -p wa -k users
-w /etc/shadow -p wa -k users
-w /etc/group -p wa -k users
-w /etc/gshadow -p wa -k users

# AppArmor
-w /etc/apparmor.d/ -p wa -k apparmor

# Privacy stack
-w /etc/privacypi/ -p wa -k privacypi-config
-w /opt/privacypi/ -p wa -k privacypi-app

# Iptables / network
-w /etc/iptables/ -p wa -k netfilter
-w /etc/sysctl.conf -p wa -k sysctl
-w /etc/sysctl.d/ -p wa -k sysctl

# Process exec (high volume — keep enabled but consider buffer size)
-a always,exit -F arch=b64 -S execve -k exec
-a always,exit -F arch=b32 -S execve -k exec

# Make rules immutable until reboot (-e 2)
-e 2
```

- [ ] **Step 2: Write the deploy script**

Create `/Users/mogli/Desktop/VPN/scripts/10-auditd.sh`:

```bash
#!/usr/bin/env bash
# Deploy and activate auditd rules.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Pushing audit rules"
pi_rsync "$REPO_ROOT/system/etc/audit/rules.d/privacypi.rules" \
         /etc/audit/rules.d/privacypi.rules

echo "==> Loading rules"
pi_ssh 'sudo augenrules --load'

echo "==> Enable + start auditd"
pi_ssh 'sudo systemctl enable --now auditd'

echo "==> Status"
pi_ssh 'sudo auditctl -s | head -10'
pi_ssh 'sudo auditctl -l | head -20'

echo "==> Done"
```

- [ ] **Step 3: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/10-auditd.sh
bash -n scripts/10-auditd.sh && echo "Syntax OK"
./scripts/10-auditd.sh

( source scripts/lib/ssh-helpers.sh && pi_ssh '
  systemctl is-active auditd && sudo auditctl -l | wc -l
' )
```

Expected: `active`, then a count > 20.

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/audit/rules.d/privacypi.rules scripts/10-auditd.sh
git commit -m "feat(security): auditd rules for tamper detection"
```

---

## Task 14: Hardware Watchdog

**Files:**
- Create: `/Users/mogli/Desktop/VPN/system/etc/systemd/system.conf.d/10-privacypi-watchdog.conf`
- Create: `/Users/mogli/Desktop/VPN/scripts/11-watchdog.sh`

Use the Pi's hardware watchdog (`bcm2835_wdt`) via systemd. If the system hangs, it auto-reboots.

- [ ] **Step 1: Write the systemd watchdog drop-in**

Create `/Users/mogli/Desktop/VPN/system/etc/systemd/system.conf.d/10-privacypi-watchdog.conf`:

```text
[Manager]
RuntimeWatchdogSec=15s
RebootWatchdogSec=2min
ShutdownWatchdogSec=10min
```

- [ ] **Step 2: Write the deploy script**

Create `/Users/mogli/Desktop/VPN/scripts/11-watchdog.sh`:

```bash
#!/usr/bin/env bash
# Enable hardware watchdog via systemd.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> Loading watchdog kernel module"
pi_ssh 'sudo modprobe bcm2835_wdt && echo "bcm2835_wdt" | sudo tee -a /etc/modules-load.d/privacypi.conf >/dev/null || true'

echo "==> Pushing systemd drop-in"
pi_ssh 'sudo install -d -m 755 /etc/systemd/system.conf.d'
pi_rsync "$REPO_ROOT/system/etc/systemd/system.conf.d/10-privacypi-watchdog.conf" \
         /etc/systemd/system.conf.d/10-privacypi-watchdog.conf

echo "==> Reloading systemd config"
pi_ssh 'sudo systemctl daemon-reexec'

echo "==> Disable competing watchdog daemon (we use systemd-native)"
pi_ssh 'sudo systemctl disable --now watchdog.service 2>/dev/null || true'

echo "==> Verify"
pi_ssh 'sudo systemctl show -p RuntimeWatchdogUSec'

echo "==> Done"
```

- [ ] **Step 3: Make sure modules-load.d/privacypi.conf in the repo also lists bcm2835_wdt**

```bash
cd /Users/mogli/Desktop/VPN
echo "bcm2835_wdt" >> system/etc/modules-load.d/privacypi.conf
sort -u system/etc/modules-load.d/privacypi.conf -o system/etc/modules-load.d/privacypi.conf
cat system/etc/modules-load.d/privacypi.conf
```

Expected: Three lines, alphabetical: `8021q`, `bcm2835_wdt`, `br_netfilter`.

Reapply the modules-load file to the Pi:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && \
  rsync -avz --rsync-path="sudo rsync" -e ssh \
    system/etc/modules-load.d/privacypi.conf \
    "${PI_USER}@${PI_HOST}:/etc/modules-load.d/privacypi.conf" )
```

- [ ] **Step 4: Run and verify**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/11-watchdog.sh
bash -n scripts/11-watchdog.sh && echo "Syntax OK"
./scripts/11-watchdog.sh

( source scripts/lib/ssh-helpers.sh && pi_ssh '
  lsmod | grep bcm2835_wdt &&
  systemctl show -p RuntimeWatchdogUSec | grep -v "^RuntimeWatchdogUSec=0$"
' )
```

Expected: Module listed; `RuntimeWatchdogUSec=15s` (or `15000000`).

- [ ] **Step 5: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add system/etc/systemd/system.conf.d/10-privacypi-watchdog.conf scripts/11-watchdog.sh system/etc/modules-load.d/privacypi.conf
git commit -m "feat(security): hardware watchdog via systemd"
```

---

## Task 15: Document Optional Hardening (LUKS, Overlayroot)

**Files:**
- Create: `/Users/mogli/Desktop/VPN/docs/ops/optional-hardening.md`

These two hardening features are optional per spec because they trade off recovery and performance. Document them so the operator can opt in later.

- [ ] **Step 1: Write the document**

Create `/Users/mogli/Desktop/VPN/docs/ops/optional-hardening.md`:

````markdown
# Optional Hardening — LUKS & Overlayroot

These are NOT installed by Plan 1. They are documented for operators who want to opt in later. Each has a real cost; read carefully before enabling.

## LUKS — Encrypted SD Card

**Pros:** SD card removed from Pi cannot be read on another machine.
**Cons:** Boot requires manual passphrase entry over serial console (no headless boot), or a network-unlock setup which adds complexity. Read/write throughput drops ~5-15%.

### When to use
- The Pi sits in a location where physical theft is plausible.
- You are willing to attach a screen + keyboard for boot, OR set up dropbear-initramfs for SSH-based unlock.

### High-level path
1. Boot Pi from a fresh image, install Ubuntu Server but pause before initial use.
2. Use a USB drive to take an image of `/`.
3. Reformat the SD card root partition with LUKS, restore the filesystem inside.
4. Update `/etc/crypttab` and `/boot/firmware/cmdline.txt` to unlock at boot.
5. Install `dropbear-initramfs` if remote unlock is desired; configure with the operator's SSH key.

References:
- https://wiki.archlinux.org/title/Dm-crypt/Encrypting_an_entire_system
- https://github.com/raspberrypi/firmware (cmdline.txt)

## Overlayroot — Read-Only Root

**Pros:** System cannot be modified at runtime; reverts to clean state on reboot. Hardens against persistence by attackers and reduces SD wear.
**Cons:** Updates require disabling overlayroot temporarily. Logs and runtime state must be redirected to writable mounts.

### When to use
- The Pi is a deploy-and-forget appliance and changes happen rarely.
- You can accept "to update, reboot to writable mode" as a workflow.

### High-level path
1. `sudo apt-get install overlayroot`.
2. Edit `/etc/overlayroot.conf`: `overlayroot="tmpfs"` (or "device:/dev/...").
3. Bind-mount writable directories that need persistence: `/var/lib/privacypi`, `/var/log/privacypi`, `/etc/privacypi`, `/var/log/audit`, `/var/lib/AdGuardHome`, etc.
4. Reboot. From now on, all changes are ephemeral unless they live in a bind-mounted writable.

To make a persistent change later: `sudo overlayroot-chroot` (drops you into the underlay), apply changes, exit, reboot.

References:
- `man overlayroot.conf`
- https://manpages.ubuntu.com/manpages/jammy/man8/overlayroot.8.html

## Recommendation for Plan 1

Skip both for now. Revisit after Plan 12 ships and the system is stable. Both are easier to add to a working system than to a half-built one.
````

- [ ] **Step 2: Verify**

```bash
test -s /Users/mogli/Desktop/VPN/docs/ops/optional-hardening.md && echo OK
```

Expected output: `OK`

- [ ] **Step 3: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add docs/ops/optional-hardening.md
git commit -m "docs(ops): document optional LUKS and overlayroot hardening"
```

---

## Task 16: Foundation Verification Suite

**Files:**
- Create: `/Users/mogli/Desktop/VPN/scripts/verify-foundation.sh`

A single command that confirms every Plan 1 control is in place.

- [ ] **Step 1: Write the verifier**

Create `/Users/mogli/Desktop/VPN/scripts/verify-foundation.sh`:

```bash
#!/usr/bin/env bash
# Plan 1 verification: confirm all foundation controls are active on the Pi.
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PASS=0
FAIL=0
report() {
  local desc="$1" cmd="$2" expect_re="$3"
  local out
  out="$(pi_ssh "$cmd" 2>&1 || true)"
  if echo "$out" | grep -Eq "$expect_re"; then
    echo "  ✓ $desc"
    PASS=$((PASS + 1))
  else
    echo "  ✗ $desc"
    echo "    cmd: $cmd"
    echo "    expected match: $expect_re"
    echo "    got: $out" | head -3
    FAIL=$((FAIL + 1))
  fi
}

echo "==> PrivacyPi Foundation Verification"
echo

echo "[ Identity ]"
report "hostname is privacypi" "hostname" "^privacypi$"
report "privacypi user exists" "id privacypi" "uid=[0-9]+\(privacypi\)"

echo "[ Kernel & sysctl ]"
report "8021q loaded" "lsmod | awk '{print \$1}'" "^8021q$"
report "br_netfilter loaded" "lsmod | awk '{print \$1}'" "^br_netfilter$"
report "bcm2835_wdt loaded" "lsmod | awk '{print \$1}'" "^bcm2835_wdt$"
report "ip_forward enabled" "sysctl -n net.ipv4.ip_forward" "^1$"
report "rp_filter enabled" "sysctl -n net.ipv4.conf.all.rp_filter" "^1$"
report "tcp_syncookies enabled" "sysctl -n net.ipv4.tcp_syncookies" "^1$"

echo "[ DNS ]"
report "systemd-resolved disabled" "systemctl is-active systemd-resolved" "^inactive$|^failed$"
report "port 53 free" "sudo ss -tulnp | grep ':53 ' | wc -l" "^0$"

echo "[ Filesystem ]"
report "/etc/privacypi exists" "test -d /etc/privacypi && echo OK" "^OK$"
report "/opt/privacypi exists" "test -d /opt/privacypi && echo OK" "^OK$"
report "/var/lib/privacypi exists" "test -d /var/lib/privacypi && echo OK" "^OK$"
report "/var/log/privacypi exists" "test -d /var/log/privacypi && echo OK" "^OK$"

echo "[ Hardening ]"
report "AppArmor enabled" "systemctl is-active apparmor" "^active$"
report "AppArmor enforcing profiles > 0" "sudo aa-status --enforced | wc -l" "^([1-9][0-9]*)$"
report "unattended-upgrades enabled" "systemctl is-enabled apt-daily-upgrade.timer" "^enabled$"
report "CrowdSec running" "systemctl is-active crowdsec" "^active$"
report "CrowdSec firewall bouncer running" "systemctl is-active crowdsec-firewall-bouncer" "^active$"
report "auditd running" "systemctl is-active auditd" "^active$"
report "auditd rules loaded > 20" "sudo auditctl -l | wc -l" "^([2-9][0-9]|[1-9][0-9]{2,})$"
report "systemd watchdog > 0" "systemctl show -p RuntimeWatchdogUSec --value" "^[1-9]"

echo "[ SSH ]"
report "sshd config valid" "sudo sshd -t && echo OK" "^OK$"
report "PasswordAuthentication off" "sudo sshd -T | grep ^passwordauthentication" "no$"
report "PermitRootLogin off" "sudo sshd -T | grep ^permitrootlogin" "no$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run it**

```bash
cd /Users/mogli/Desktop/VPN
chmod +x scripts/verify-foundation.sh
bash -n scripts/verify-foundation.sh && echo "Syntax OK"
./scripts/verify-foundation.sh
```

Expected: All checks `✓`, final line `==> Result: 22 passed, 0 failed`. If any fail, fix the underlying task before proceeding.

- [ ] **Step 3: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add scripts/verify-foundation.sh
git commit -m "feat(scripts): foundation verification suite"
```

---

## Task 17: Update TRACKER.md

**Files:**
- Modify: `/Users/mogli/Desktop/VPN/TRACKER.md`

Mark Phase 1 and Phase 2 tasks complete.

- [ ] **Step 1: Mark every Phase 1 task complete**

Edit `/Users/mogli/Desktop/VPN/TRACKER.md`. Find the `### Phase 1 — OS & Base Setup` block. Replace each `- [ ]` with `- [x]` for every line in that block.

- [ ] **Step 2: Mark every Phase 2 task complete**

Same for `### Phase 2 — Pi Hardening (Critical Foundation)`. Replace every `- [ ]` with `- [x]`.

- [ ] **Step 3: Add a session-log entry**

Append a row to the `## Session Log` table:

```markdown
| 2026-05-01 | Plan 1 (Foundation) executed: Pi flashed, hardened, verified — 22/22 checks pass |
```

- [ ] **Step 4: Commit**

```bash
cd /Users/mogli/Desktop/VPN
git add TRACKER.md
git commit -m "chore(tracker): mark Phase 1 and Phase 2 complete"
```

---

## Task 18: Plan 1 Closeout

**Files:**
- None modified.

Confirm we are ready for Plan 2.

- [ ] **Step 1: Final smoke check**

```bash
cd /Users/mogli/Desktop/VPN
./scripts/verify-foundation.sh
```

Expected: `22 passed, 0 failed`.

- [ ] **Step 2: Confirm git tree is clean**

```bash
cd /Users/mogli/Desktop/VPN
git status
```

Expected: `nothing to commit, working tree clean`.

- [ ] **Step 3: Document closeout in the audit trail**

The Pi's auditd should now have records of every config change made during this plan:

```bash
cd /Users/mogli/Desktop/VPN
( source scripts/lib/ssh-helpers.sh && pi_ssh 'sudo aureport -k --summary | head -20' )
```

Expected: A non-empty summary listing the keys defined in `privacypi.rules` (`auditconfig`, `sshd`, `apparmor`, `privacypi-config`, etc.).

- [ ] **Step 4: Tag the milestone**

```bash
cd /Users/mogli/Desktop/VPN
git tag -a plan-01-complete -m "Plan 1: Foundation complete — Pi flashed, hardened, verified"
git tag -l
```

Expected: `plan-01-complete` listed.

---

## Done

Plan 1 is complete. The Pi is:
- Running Ubuntu Server 24.04 LTS
- Hardened: AppArmor enforcing, unattended-upgrades active, CrowdSec running, auditd logging, hardware watchdog, SSH key-only
- Configured: kernel modules + sysctls for routing, port 53 free, canonical directory layout, dedicated `privacypi` user

**Next:** Plan 2 — Network & Routing (multi-SSID hostapd + VLANs + per-VLAN kill switch).
