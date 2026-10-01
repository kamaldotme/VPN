# PrivacyPi — Plan 2: Network & Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: superpowers:subagent-driven-development or superpowers:executing-plans.

**Goal:** Bring up multi-SSID AP on `wlan1` (Edimax) with VLAN segmentation, per-VLAN DHCP, per-VLAN routing tables, and a kernel-level kill switch infrastructure. End state: 6 SSIDs broadcasting (or as many as the chipset supports), each VLAN routes through `eth0` to the internet, all leak vectors blocked at the iptables level.

**Architecture:** hostapd 2.10+ with multiple `bss=` directives; dnsmasq with `dhcp-range` per interface; bridges per VLAN; iptables `FORWARD` defaults DROP, per-VLAN allow chains; default route per VLAN points to `eth0` for now (later plans add VPN/Tor tunnels). `wlan0`-as-WiFi-client is **deferred to a later plan** — Ethernet stays connected for Plan 2.

**Tech Stack:** hostapd, dnsmasq, iproute2 (bridges, VLANs, multiple routing tables), iptables, ipset, netplan, systemd networkd-wait-online disabled (we own networking).

---

## Critical Pre-Flight Check

Before committing to 6 SSIDs, confirm what the Edimax adapter can do. Many cheap USB adapters cap at 1-4 BSS. Plan 2 starts with capability detection and scopes accordingly.

| Detected `valid_iftypes_nodes` | Plan 2 SSID set |
|---|---|
| AP supported, ≥6 BSS | Full set (6 SSIDs) |
| AP supported, 4 BSS | Drop `IoT` + `Guest`, keep 4 |
| AP supported, 2 BSS | Just `Direct` + `VPN`, document Plan 3 will add more |
| AP supported, 1 BSS | Single SSID with per-device routing only |
| No AP support | **Stop**: need different USB adapter, document model |

We always proceed with **at least one SSID**, never zero.

---

## File Structure

```
/Users/mogli/Desktop/VPN/
├── system/etc/
│   ├── hostapd/
│   │   └── hostapd.conf              ← multi-SSID + VLAN
│   ├── dnsmasq.d/
│   │   └── privacypi.conf            ← per-VLAN DHCP
│   ├── iproute2/
│   │   └── rt_tables.d/
│   │       └── privacypi.conf        ← VLAN routing table IDs
│   ├── netplan/
│   │   └── 50-privacypi.yaml         ← bridge + VLAN definitions
│   ├── systemd/
│   │   └── system/
│   │       └── privacypi-firewall.service ← iptables apply on boot
│   └── default/
│       └── hostapd                   ← hostapd defaults
├── opt/privacypi/scripts/            ← deployed to Pi
│   ├── firewall-base.sh              ← default-DROP + leak blocks
│   ├── routing-vlan.sh               ← per-VLAN tables + ip rule
│   └── killswitch.sh                 ← arm/disarm helper
├── scripts/
│   ├── 12-detect-wifi-caps.sh        ← chipset capability probe
│   ├── 13-deploy-network.sh          ← orchestrator
│   ├── 14-deploy-firewall.sh         ← orchestrator
│   └── verify-network.sh             ← end-to-end checks
```

---

## Conventions

- All Pi-side scripts deployed to `/opt/privacypi/scripts/` (created in Plan 1).
- iptables changes are atomic where possible (use `iptables-restore`).
- Every step has a verify command. We don't trust services to be "up" without proof.

---

## Task 1: Detect WiFi Adapter Capabilities

**Files:**
- Create: `scripts/12-detect-wifi-caps.sh`
- Create: `docs/ops/wifi-capabilities.md`

- [ ] **Step 1: Write the probe script**

```bash
cat > scripts/12-detect-wifi-caps.sh <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

echo "==> WiFi adapters detected:"
pi_ssh 'iw dev | awk "/Interface/ {print \"  \", \$2}"'
echo
echo "==> Driver / chipset:"
pi_ssh 'for i in $(iw dev | awk "/Interface/ {print \$2}"); do
  echo "  $i:"
  ethtool -i $i 2>/dev/null | grep -E "^driver|^bus-info" | sed "s/^/    /"
done'
echo
echo "==> AP capabilities + max BSS per phy:"
pi_ssh 'iw list 2>/dev/null | awk "
  /^Wiphy/ {phy=\$2}
  /Supported interface modes/ {ap_mode=0}
  /\* AP$/ {ap_mode=1}
  /valid interface combinations/ {comb=1}
  comb && /total <= [0-9]/ {match(\$0, /total <= [0-9]+/); total=substr(\$0,RSTART+9,RLENGTH-9); print phy, \"AP=\"ap_mode, \"max_total=\"total}
  /^Wiphy [a-z0-9]+$/ {comb=0}
"'
EOF
chmod +x scripts/12-detect-wifi-caps.sh
```

- [ ] **Step 2: Run it**

```bash
./scripts/12-detect-wifi-caps.sh
```

- [ ] **Step 3: Decide SSID count, document**

Write `docs/ops/wifi-capabilities.md` with the chipset, max BSS, and the SSID set we'll use.

- [ ] **Step 4: Commit**

```bash
git add scripts/12-detect-wifi-caps.sh docs/ops/wifi-capabilities.md
git commit -m "feat(plan-02): detect WiFi adapter capabilities"
```

---

## Task 2: hostapd Configuration

**Files:**
- Create: `system/etc/hostapd/hostapd.conf`
- Create: `system/etc/default/hostapd`

The base hostapd.conf will be **conditionally generated** based on Task 1's detection — the deploy script in Task 5 customizes it before pushing.

- [ ] **Step 1: Write the hostapd template**

Save a template that supports up to 6 SSIDs; the deploy script will trim based on capability.

```ini
# /etc/hostapd/hostapd.conf
interface=wlan1
driver=nl80211
country_code=IN
ieee80211n=1
wmm_enabled=1
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

# Primary BSS (always present)
ssid=PrivacyPi-Direct
wpa_passphrase=PRIVACYPI_DIRECT_PASSWORD
bridge=br-vlan10

# Additional BSS entries appended by deploy-network.sh based on capability:
# bss=wlan1_1
# ssid=PrivacyPi-VPN
# ...
```

- [ ] **Step 2: hostapd defaults file**

```text
# /etc/default/hostapd
DAEMON_CONF="/etc/hostapd/hostapd.conf"
```

- [ ] **Step 3: Commit (template only, not deployed yet)**

```bash
git add system/etc/hostapd/ system/etc/default/hostapd
git commit -m "feat(plan-02): hostapd multi-SSID template"
```

---

## Task 3: Netplan + Bridges + VLAN Plan

**Files:**
- Create: `system/etc/netplan/50-privacypi.yaml`

Per-VLAN bridges receive hostapd traffic. Each bridge gets its `.1` IP. The bridges are *not* wired to wlan1 directly here — hostapd's `bridge=` directive does that at runtime.

- [ ] **Step 1: Write netplan**

```yaml
# /etc/netplan/50-privacypi.yaml
network:
  version: 2
  renderer: networkd
  ethernets:
    eth0:
      dhcp4: true
      optional: true
  bridges:
    br-vlan10:
      addresses: [10.10.10.1/24]
      parameters:
        forward-delay: 0
        stp: false
    br-vlan20:
      addresses: [10.10.20.1/24]
      parameters:
        forward-delay: 0
        stp: false
    br-vlan30:
      addresses: [10.10.30.1/24]
      parameters:
        forward-delay: 0
        stp: false
    br-vlan40:
      addresses: [10.10.40.1/24]
      parameters:
        forward-delay: 0
        stp: false
    br-vlan60:
      addresses: [10.10.60.1/24]
      parameters:
        forward-delay: 0
        stp: false
    br-vlan70:
      addresses: [10.10.70.1/24]
      parameters:
        forward-delay: 0
        stp: false
```

- [ ] **Step 2: Commit**

```bash
git add system/etc/netplan/50-privacypi.yaml
git commit -m "feat(plan-02): netplan with per-VLAN bridges"
```

---

## Task 4: dnsmasq Per-VLAN DHCP

**Files:**
- Create: `system/etc/dnsmasq.d/privacypi.conf`

- [ ] **Step 1: Write dnsmasq config**

```ini
# /etc/dnsmasq.d/privacypi.conf
# Don't read /etc/resolv.conf
no-resolv
# Don't function as a DNS resolver yet (AdGuard Home owns 53 in Plan 3)
port=0
# DHCP only
dhcp-authoritative
log-dhcp

# Per-VLAN scope
interface=br-vlan10
interface=br-vlan20
interface=br-vlan30
interface=br-vlan40
interface=br-vlan60
interface=br-vlan70
bind-interfaces

# Per-bridge DHCP ranges
dhcp-range=set:vlan10,10.10.10.50,10.10.10.250,255.255.255.0,12h
dhcp-range=set:vlan20,10.10.20.50,10.10.20.250,255.255.255.0,12h
dhcp-range=set:vlan30,10.10.30.50,10.10.30.250,255.255.255.0,12h
dhcp-range=set:vlan40,10.10.40.50,10.10.40.250,255.255.255.0,12h
dhcp-range=set:vlan60,10.10.60.50,10.10.60.250,255.255.255.0,12h
dhcp-range=set:vlan70,10.10.70.50,10.10.70.250,255.255.255.0,12h

# Default gateway = the Pi's bridge IP, served per VLAN
dhcp-option=tag:vlan10,3,10.10.10.1
dhcp-option=tag:vlan20,3,10.10.20.1
dhcp-option=tag:vlan30,3,10.10.30.1
dhcp-option=tag:vlan40,3,10.10.40.1
dhcp-option=tag:vlan60,3,10.10.60.1
dhcp-option=tag:vlan70,3,10.10.70.1

# DNS = Pi (port 53 will be served by AdGuard Home in Plan 3)
dhcp-option=tag:vlan10,6,10.10.10.1
dhcp-option=tag:vlan20,6,10.10.20.1
dhcp-option=tag:vlan30,6,10.10.30.1
dhcp-option=tag:vlan40,6,10.10.40.1
dhcp-option=tag:vlan60,6,10.10.60.1
dhcp-option=tag:vlan70,6,10.10.70.1
```

- [ ] **Step 2: Commit**

```bash
git add system/etc/dnsmasq.d/privacypi.conf
git commit -m "feat(plan-02): per-VLAN DHCP via dnsmasq"
```

---

## Task 5: Routing Tables Definition

**Files:**
- Create: `system/etc/iproute2/rt_tables.d/privacypi.conf`

- [ ] **Step 1: Write rt_tables**

```text
# /etc/iproute2/rt_tables.d/privacypi.conf
100  privacypi-vlan10
200  privacypi-vlan20
300  privacypi-vlan30
400  privacypi-vlan40
600  privacypi-vlan60
700  privacypi-vlan70
```

- [ ] **Step 2: Commit**

```bash
git add system/etc/iproute2/rt_tables.d/privacypi.conf
git commit -m "feat(plan-02): per-VLAN routing table IDs"
```

---

## Task 6: Firewall + Kill Switch Scripts

**Files:**
- Create: `opt/privacypi/scripts/firewall-base.sh`
- Create: `opt/privacypi/scripts/routing-vlan.sh`
- Create: `opt/privacypi/scripts/killswitch.sh`
- Create: `system/etc/systemd/system/privacypi-firewall.service`

- [ ] **Step 1: firewall-base.sh — apply base rules**

```bash
#!/usr/bin/env bash
# Apply iptables base rules: default-DROP forward, NAT to eth0, leak blocks.
set -euo pipefail

# Flush, set defaults
iptables -P INPUT ACCEPT
iptables -P FORWARD DROP
iptables -P OUTPUT ACCEPT
iptables -F
iptables -t nat -F
iptables -t mangle -F
iptables -X
iptables -t nat -X

# NAT: masquerade out eth0 (later plans add tun0/wg0 etc.)
iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE

# Per-VLAN forward chains (initial: allow direct out via eth0)
for vlan_iface in br-vlan10 br-vlan20 br-vlan30 br-vlan40 br-vlan60 br-vlan70; do
  iptables -N FWD-$vlan_iface 2>/dev/null || iptables -F FWD-$vlan_iface
  iptables -A FORWARD -i $vlan_iface -j FWD-$vlan_iface
  iptables -A FWD-$vlan_iface -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
  # Direct route to eth0 (will be replaced per-VLAN by VPN/Tor in later plans)
  iptables -A FWD-$vlan_iface -o eth0 -j ACCEPT
done
# Return traffic
iptables -A FORWARD -i eth0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

# === Leak prevention ===

# Block WebRTC/STUN
for port in 3478 3479 5349 5350; do
  iptables -A FORWARD -p udp --dport $port -j DROP
  iptables -A FORWARD -p tcp --dport $port -j DROP
done

# Block UPnP
iptables -A FORWARD -p udp --dport 1900 -j DROP

# Block NetBIOS
iptables -A FORWARD -p udp --dport 137:139 -j DROP
iptables -A FORWARD -p tcp --dport 137:139 -j DROP

# Block LLMNR
iptables -A FORWARD -p udp --dport 5355 -j DROP

# Force DNS to Pi (clients can't bypass) — redirect to Pi's bridge IP
for vlan in 10 20 30 40 60 70; do
  iptables -t nat -A PREROUTING -i br-vlan$vlan -p udp ! -d 10.10.$vlan.1 --dport 53 -j DNAT --to-destination 10.10.$vlan.1
  iptables -t nat -A PREROUTING -i br-vlan$vlan -p tcp ! -d 10.10.$vlan.1 --dport 53 -j DNAT --to-destination 10.10.$vlan.1
done

# Save
iptables-save > /etc/iptables/rules.v4
ip6tables -P FORWARD DROP
ip6tables-save > /etc/iptables/rules.v6

echo "Base firewall applied."
```

- [ ] **Step 2: routing-vlan.sh — per-VLAN ip rules**

```bash
#!/usr/bin/env bash
# Set up per-VLAN routing tables. Initial: all → eth0 default route.
set -euo pipefail

GW="$(ip -4 route show default | awk '/default/{print $3; exit}')"
[[ -z "$GW" ]] && { echo "no default gateway found"; exit 1; }

declare -A VLANS=(
  [10]=br-vlan10  [20]=br-vlan20  [30]=br-vlan30
  [40]=br-vlan40  [60]=br-vlan60  [70]=br-vlan70
)
declare -A TABLES=(
  [10]=100  [20]=200  [30]=300  [40]=400  [60]=600  [70]=700
)

for vlan in 10 20 30 40 60 70; do
  iface="${VLANS[$vlan]}"
  table="${TABLES[$vlan]}"
  ip route flush table $table 2>/dev/null || true
  ip route add 10.10.$vlan.0/24 dev $iface src 10.10.$vlan.1 table $table
  ip route add default via $GW dev eth0 table $table
  # Source-based routing
  ip rule del from 10.10.$vlan.0/24 table $table 2>/dev/null || true
  ip rule add from 10.10.$vlan.0/24 table $table
done

echo "Per-VLAN routing applied."
```

- [ ] **Step 3: killswitch.sh — arm/disarm helper**

```bash
#!/usr/bin/env bash
# Per-VLAN kill switch arm/disarm.
# Usage: killswitch.sh arm|disarm <vlan>
set -euo pipefail

ACTION="${1:-}"
VLAN="${2:-}"
IFACE="br-vlan${VLAN}"

case "$ACTION" in
  arm)
    iptables -F FWD-${IFACE}
    iptables -A FWD-${IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    # NO outbound allow rules: traffic dies here
    echo "Kill switch ARMED on VLAN $VLAN ($IFACE)"
    ;;
  disarm)
    iptables -F FWD-${IFACE}
    iptables -A FWD-${IFACE} -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -A FWD-${IFACE} -o eth0 -j ACCEPT
    echo "Kill switch DISARMED on VLAN $VLAN — direct internet"
    ;;
  *)
    echo "Usage: $0 {arm|disarm} <vlan>" >&2
    exit 2
    ;;
esac
```

- [ ] **Step 4: systemd unit to apply firewall on boot**

```ini
# /etc/systemd/system/privacypi-firewall.service
[Unit]
Description=PrivacyPi base firewall
After=network-pre.target
Wants=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/opt/privacypi/scripts/firewall-base.sh
ExecStartPost=/opt/privacypi/scripts/routing-vlan.sh
RemainAfterExit=true

[Install]
WantedBy=multi-user.target
```

- [ ] **Step 5: Commit**

```bash
git add opt/privacypi/scripts/ system/etc/systemd/system/privacypi-firewall.service
git commit -m "feat(plan-02): firewall base + per-VLAN routing + kill switch"
```

---

## Task 7: Deploy Network Stack to Pi

**Files:**
- Create: `scripts/13-deploy-network.sh`

This is the orchestrator that pushes config files, generates the multi-SSID hostapd.conf based on detected capabilities, and starts the services.

- [ ] **Step 1: Write the deploy script** (handles the capability-driven hostapd generation)

```bash
#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

# 1. Detect max BSS
MAX_BSS=$(pi_ssh 'iw list 2>/dev/null | awk "
  /Wiphy/ {phy=\$2}
  /valid interface combinations/ {flag=1}
  flag && /total <= [0-9]/ {match(\$0, /total <= [0-9]+/); print substr(\$0,RSTART+9,RLENGTH-9); exit}
"')
MAX_BSS="${MAX_BSS:-1}"
echo "==> Max BSS = $MAX_BSS"

# Determine SSID set based on capability
declare -a SSIDS=("PrivacyPi-Direct:10:vlan10" "PrivacyPi-VPN:20:vlan20" "PrivacyPi-Tor:30:vlan30" "PrivacyPi-Proxy:40:vlan40" "PrivacyPi-Guest:60:vlan60" "PrivacyPi-IoT:70:vlan70")
ACTIVE_SSIDS=("${SSIDS[@]:0:$MAX_BSS}")
echo "==> Activating ${#ACTIVE_SSIDS[@]} SSID(s):"
printf "    %s\n" "${ACTIVE_SSIDS[@]}"

# 2. Generate hostapd.conf with the active SSIDs
TMPCONF=$(mktemp)
cat > "$TMPCONF" <<EOF
interface=wlan1
driver=nl80211
country_code=IN
ieee80211n=1
wmm_enabled=1
hw_mode=g
channel=6
auth_algs=1
wpa=2
wpa_key_mgmt=WPA-PSK
rsn_pairwise=CCMP

EOF

i=0
for entry in "${ACTIVE_SSIDS[@]}"; do
  IFS=':' read -r ssid vlan bridge <<< "$entry"
  if [[ $i -eq 0 ]]; then
    cat >> "$TMPCONF" <<EOF
ssid=$ssid
wpa_passphrase=privacypi
bridge=br-$bridge

EOF
  else
    cat >> "$TMPCONF" <<EOF
bss=wlan1_$i
ssid=$ssid
wpa_passphrase=privacypi
bridge=br-$bridge

EOF
  fi
  i=$((i+1))
done

# 3. Push everything in parallel where possible
echo "==> Pushing configs to Pi"
(rsync -az --rsync-path="sudo rsync" -e ssh "$TMPCONF" "$PI_USER@$PI_HOST:/etc/hostapd/hostapd.conf" && echo "  ✓ hostapd.conf") &
(rsync -az --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/system/etc/default/hostapd" "$PI_USER@$PI_HOST:/etc/default/hostapd" && echo "  ✓ /etc/default/hostapd") &
(rsync -az --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/system/etc/netplan/50-privacypi.yaml" "$PI_USER@$PI_HOST:/etc/netplan/50-privacypi.yaml" && pi_ssh 'sudo chmod 600 /etc/netplan/50-privacypi.yaml' && echo "  ✓ netplan") &
(rsync -az --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/system/etc/dnsmasq.d/privacypi.conf" "$PI_USER@$PI_HOST:/etc/dnsmasq.d/privacypi.conf" && echo "  ✓ dnsmasq") &
(pi_ssh 'sudo install -d -m 755 /etc/iproute2/rt_tables.d' && rsync -az --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/system/etc/iproute2/rt_tables.d/privacypi.conf" "$PI_USER@$PI_HOST:/etc/iproute2/rt_tables.d/" && echo "  ✓ rt_tables") &
(pi_ssh 'sudo install -d -m 755 /opt/privacypi/scripts' && rsync -az --chmod=755 --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/opt/privacypi/scripts/" "$PI_USER@$PI_HOST:/opt/privacypi/scripts/" && echo "  ✓ /opt/privacypi/scripts") &
(rsync -az --rsync-path="sudo rsync" -e ssh "$REPO_ROOT/system/etc/systemd/system/privacypi-firewall.service" "$PI_USER@$PI_HOST:/etc/systemd/system/" && echo "  ✓ systemd unit") &
wait

rm -f "$TMPCONF"

# 4. Install hostapd + dnsmasq if not already (Plan 1 didn't include these)
echo "==> Ensuring hostapd + dnsmasq packages installed"
pi_ssh 'sudo DEBIAN_FRONTEND=noninteractive apt-get install -y hostapd dnsmasq 2>&1 | tail -5'

# 5. Disable services we DON'T want
echo "==> Disable systemd-networkd-wait-online (we manage networking)"
pi_ssh 'sudo systemctl disable --now systemd-networkd-wait-online.service 2>&1 | tail -2 || true'

# 6. Apply netplan
echo "==> Applying netplan"
pi_ssh 'sudo netplan apply 2>&1 | head -10'
sleep 3
pi_ssh 'ip -br addr show | grep -E "br-vlan|eth0|wlan"'

# 7. Unmask + enable hostapd
echo "==> Enabling hostapd + dnsmasq"
pi_ssh '
  sudo systemctl unmask hostapd 2>&1 | tail -2
  sudo systemctl enable hostapd dnsmasq 2>&1 | tail -2
  sudo systemctl restart hostapd dnsmasq 2>&1 | tail -2
'
sleep 2

# 8. Apply firewall + routing
echo "==> Enabling firewall service"
pi_ssh '
  sudo systemctl daemon-reload
  sudo systemctl enable --now privacypi-firewall.service 2>&1 | tail -3
'

# 9. Status check
echo "==> Status:"
pi_ssh 'systemctl is-active hostapd dnsmasq privacypi-firewall'
```

- [ ] **Step 2: Run + verify**

```bash
chmod +x scripts/13-deploy-network.sh
./scripts/13-deploy-network.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/13-deploy-network.sh
git commit -m "feat(plan-02): network stack deploy orchestrator"
```

---

## Task 8: Verification Suite

**Files:**
- Create: `scripts/verify-network.sh`

- [ ] **Step 1: Write verifier**

```bash
#!/usr/bin/env bash
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/ssh-helpers.sh"

PASS=0; FAIL=0
report() {
  local desc="$1" cmd="$2" expect_re="$3"
  local out; out="$(pi_ssh "$cmd" 2>&1 || true)"
  if echo "$out" | grep -Eq "$expect_re"; then
    echo "  ✓ $desc"; PASS=$((PASS+1))
  else
    echo "  ✗ $desc"
    echo "    cmd: $cmd"; echo "    got: $(echo "$out" | head -1)"
    FAIL=$((FAIL+1))
  fi
}

echo "==> PrivacyPi Network Verification"
echo
echo "[ Bridges ]"
for v in 10 20 30 40 60 70; do
  report "br-vlan$v has 10.10.$v.1" "ip -4 addr show dev br-vlan$v 2>/dev/null | grep inet" "10\.10\.$v\.1/24"
done

echo "[ Services ]"
report "hostapd active" "systemctl is-active hostapd" "^active$"
report "dnsmasq active" "systemctl is-active dnsmasq" "^active$"
report "privacypi-firewall active" "systemctl is-active privacypi-firewall" "^active$"

echo "[ Firewall ]"
report "FORWARD policy DROP" "sudo iptables -L FORWARD -n | head -1" "policy DROP"
report "POSTROUTING masquerade on eth0" "sudo iptables -t nat -L POSTROUTING -n" "MASQUERADE.*eth0"
report "DNS forced to Pi (vlan10)" "sudo iptables -t nat -L PREROUTING -n -v | grep br-vlan10" "DNAT"
report "WebRTC port 3478 blocked" "sudo iptables -L FORWARD -n | grep dpt:3478" "DROP"
report "UPnP port 1900 blocked" "sudo iptables -L FORWARD -n | grep dpt:1900" "DROP"

echo "[ Routing tables ]"
for v in 10 20 30 40 60 70; do
  report "VLAN $v table has default route" "ip route show table $((v*10))" "default via"
done

echo "[ hostapd broadcast ]"
report "wlan1 in AP mode" "iw dev wlan1 info 2>/dev/null | grep type" "type AP"

echo "[ Kill switch helper ]"
report "killswitch.sh executable" "test -x /opt/privacypi/scripts/killswitch.sh && echo OK" "^OK$"

echo
echo "==> Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]] || exit 1
```

- [ ] **Step 2: Run**

```bash
chmod +x scripts/verify-network.sh
./scripts/verify-network.sh
```

- [ ] **Step 3: Commit**

```bash
git add scripts/verify-network.sh
git commit -m "feat(plan-02): network verification suite"
```

---

## Task 9: Update Tracker + Tag

- [ ] Mark Phase 3 + Phase 4 complete in `TRACKER.md`. Add session log entry. Tag `plan-02-complete`.

```bash
git tag -a plan-02-complete -m "Plan 2: multi-SSID AP + per-VLAN kill switch"
```

---

## Done

End state: 1-6 SSIDs broadcasting on `wlan1`, devices get DHCP per VLAN, all traffic routes through `eth0` to internet, kill switch armable per-VLAN, leak vectors blocked.

**Next:** Plan 3 — DNS stack (AdGuard Home + Unbound + Handshake).
