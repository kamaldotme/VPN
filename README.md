# PrivacyPi

Turn a Raspberry Pi into a private WiFi router. Every device that joins its WiFi gets ads and
trackers blocked and DNS encrypted — and, if you want, all traffic sent through **your VPN
(NordVPN, ExpressVPN, …)** or **Tor**. No apps to install on your phones, TVs or laptops.

**Version 2.6.0 — pre-release.** Current state and open items: [`STATUS.md`](STATUS.md).

---

## What you need

- Raspberry Pi 4 or Pi 5, power supply, microSD card (8 GB or more)
- A network cable from the Pi to your home router
  *(or a USB WiFi adapter — then the Pi can join your home WiFi instead of using a cable)*

## Set it up (about 5 minutes, no keyboard or screen on the Pi)

1. **Download** `privacypi-<version>.img.xz`.
2. **Flash** it to the SD card with [Raspberry Pi Imager](https://www.raspberrypi.com/software/)
   (*Choose OS → Use custom*) or balenaEtcher. If Imager asks about customisation settings, choose **No**.
3. **Insert** the card, plug in the network cable, **power on**. Wait about 2 minutes
   (the first start takes longer).
4. On your phone or laptop, join the WiFi **`PrivacyPi-Setup`** — password **`privacypi`**.
5. The setup page opens by itself. If it doesn't, open **http://10.10.10.1** in a browser.
6. Follow the four steps: dashboard password → internet → name your WiFi → privacy level.
7. Join **your new WiFi**. Done — everything on it is protected.

The dashboard is at **http://10.10.10.1** (or `http://privacypi.local`) while you are on your PrivacyPi WiFi.

### Add your VPN

Dashboard → **VPN providers**:

- **NordVPN** — enter your *service credentials* (Nord Account → NordVPN → *Manual setup*; this is not
  your email login), **Save**, pick a country or leave *Fastest*, **Connect**.
- **ExpressVPN and others** — enter the *manual configuration* username/password from your provider's
  website, upload the `.ovpn` (or WireGuard `.conf`) file for the server you want, **Connect**.

If the VPN drops, devices lose internet instead of leaking; it reconnects by itself, also after a restart.

### Locked out?

Put the SD card in a computer and open the small `bootfs` drive:

- `privacypi-config.txt` — remove the `#` in front of `reset=yes` to factory-reset on the next start.
- `privacypi-status.txt` — a health report written on every start (no passwords in it). Attach it when asking for help.

---

## What's inside

| Layer | What's running |
|---|---|
| 📡 **WiFi** | hostapd. Radio roles are detected at every boot by capability, not adapter model (`net-roles.sh`): built-in radio alone = access point; add a USB adapter and the Pi can also join an upstream WiFi |
| 🌐 **DNS** | AdGuard Home (blocklists) → Unbound (DNSSEC) → DNS-over-TLS upstream; clients cannot bypass it |
| 🔐 **VPN** | OpenVPN + WireGuard clients (`vpn-connect.sh`), NordVPN server auto-selection, kill-switch by construction |
| 🧅 **Tor** | Transparent Tor for all clients, bridges/pluggable transports |
| 🥷 **Proxies** | shadowsocks-rust, xray-core, tun2socks |
| 🛡️ **Firewall** | Dashboard, DNS and admin ports reachable from the PrivacyPi WiFi only; upstream network sees nothing |
| 💻 **Dashboard** | Flask behind Caddy — plain HTTP on the PrivacyPi WiFi (no certificate warning) and HTTPS for devices that install the root certificate. Optional two-step login |
| 🧩 **Extras** | I2P, Yggdrasil, Lokinet — installed on demand from the dashboard, not in the image |

No secrets are baked into the image: keys and passwords are generated on each device's first boot
(`boot-init.sh` → `provision.sh`).

## Building the image

```bash
./build-image.sh        # needs only Docker → build/privacypi-<version>.img.xz
```

It downloads the official Raspberry Pi OS Lite (64-bit) image, verifies its checksum and installs
PrivacyPi into it inside a container (`install.sh` in image-build mode).

## Testing without hardware

```bash
tests/e2e.sh            # boots the installed system in a container and plays a WiFi client through
                        # first boot → captive portal → wizard → internet → dashboard → VPN → Tor → reset
```

Everything except the radio itself is covered. `tests/test-net-roles.sh` covers radio-role detection
with simulated adapters.

## Developer install (on a running Pi)

```bash
git clone <this-repo> privacypi && cd privacypi
sudo bash install.sh && sudo reboot
```

For SSH on an image-flashed device, set `ssh_password=…` in `privacypi-config.txt` (user `pi`).

## Repo layout

```
install.sh               installer (image-build mode + developer mode)
build-image.sh, tools/   image build
app/                     Flask dashboard + setup wizard
opt/privacypi/scripts/   privileged helpers (route-mode, vpn-connect, net-roles, ap-config, …)
system/                  config files and systemd units deployed to the device
tests/                   hardware-free tests
docs/                    original spec, plans, May 2026 build history
```

## Threat model

**Protects against:** ISP surveillance, DNS snooping, ad/tracker profiling, censorship, malware C2
(DNS blocklists), untrusted upstream networks (hotel/café WiFi).

**Does not protect against:** compromised devices, browser fingerprinting, a malicious VPN provider,
physical access to the Pi, legal compulsion.
