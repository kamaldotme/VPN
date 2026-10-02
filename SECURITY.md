# Security policy

PrivacyPi is a privacy router. A flaw that leaks traffic or opens the device to others matters more
here than in most projects, so reports are very welcome.

## Supported versions

Only the latest release is supported. At the moment that is **2.6.0**, a pre-release. There is no
over-the-air update: a fix reaches users as a new image that they flash.

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Open a private security advisory on GitHub: on the repository page go to **Security** →
**Advisories** → **Report a vulnerability**. Only the maintainers can see it.

Please include:

- the PrivacyPi version (top of `privacypi-status.txt`, or the `VERSION` file),
- what an attacker needs (on the PrivacyPi WiFi? on the upstream network? logged in?),
- steps to reproduce, and what happens,
- the relevant part of `privacypi-status.txt` if it helps. It contains no passwords, but check it
  for anything you want to keep private.

Never include real VPN credentials, WiFi passwords or keys.

This is a volunteer project, so there is no guaranteed response time. You will get an
acknowledgement, an assessment, and credit in the release notes if you want it. Please give the
maintainers reasonable time to release a fixed image before publishing details.

## In scope

- **Leaks:** client traffic leaving outside the VPN tunnel or Tor while such a mode is active,
  traffic passing while the kill switch is on, or plain DNS escaping the Pi's resolver.
- **Exposure:** the dashboard, DNS, AdGuard Home, Tor ports or any other service being reachable
  from the upstream (WAN) network when `admin_on_wan` is not set.
- **Setup mode:** getting internet access through, or anything other than the wizard out of, the
  `PrivacyPi-Setup` network.
- **Dashboard:** authentication or two-step login bypass, lockout bypass, CSRF, injection, access
  to wizard steps without having set the password, session handling flaws.
- **Privilege boundary:** using the dashboard user (`privacypi`), `services/runner.py`, the sudoers
  file or any script in `opt/privacypi/scripts` to run arbitrary commands or write arbitrary files
  as root; arguments or uploaded VPN configuration files that get past validation or sanitising.
- **Secrets:** anything device-specific baked into a built image; passwords or keys appearing in
  `privacypi-status.txt`, logs or the audit log.
- **Build:** the image build pulling unverified or unpinned components.

## Out of scope

- **Physical access.** The SD card is not encrypted. Anyone holding it can read saved VPN
  credentials and WiFi passwords, and can factory-reset the device through `privacypi-config.txt`.
  That rescue path is deliberate.
- **The default setup password** (see below).
- **Options a user turned on deliberately:** `admin_on_wan=yes`, and `ssh_password=` (developer
  access: it enables SSH for user `pi` with passwordless sudo, and port 22 is accepted on every
  interface).
- **Attacks that need the dashboard password**, where the result is something the dashboard lets an
  administrator do anyway.
- **Documented limits of the threat model:** compromised client devices, browser fingerprinting, a
  malicious VPN provider, legal compulsion. Also the documented fact that apps using their own
  encrypted DNS (DoH) bypass the ad blocker by default.
- **Bugs in upstream software** (Raspberry Pi OS, AdGuard Home, Unbound, Tor, OpenVPN, WireGuard,
  hostapd, Caddy). Report those upstream. Do tell us if PrivacyPi's configuration makes one
  exploitable.
- Material under `docs/history`, `docs/superpowers` and `docs/ops`, which describes an old version.

Features that are present but not active in this release (see [STATUS.md](STATUS.md)) are lower
priority, but a report is still useful if their code is reachable from the dashboard.

## Design decisions that look like weaknesses

### The setup WiFi password is public

Every freshly flashed PrivacyPi broadcasts `PrivacyPi-Setup` with the password `privacypi`. This is
intentional:

- The device has no screen or keyboard. A per-device password would have to be printed somewhere the
  user cannot see.
- The image is identical for everyone. Nothing device-specific is baked in; unique secrets are
  generated on the first start.
- While setup is pending, that network is captive: no traffic is forwarded to the internet, every
  DNS name resolves to the Pi, and the only thing served is the setup wizard. There are no user
  settings or credentials on the device yet.
- The wizard refuses to keep the setup name or the setup password. Finishing it replaces both and
  restarts the Pi.

The remaining risk is that someone within radio range completes the wizard before the owner does.
The owner notices at once (their chosen password does not work) and recovers with `reset=yes` in
`privacypi-config.txt`. Users are told to finish setup soon after the first start.

### The dashboard is served over plain HTTP

On the PrivacyPi WiFi the dashboard is at `http://10.10.10.1`. A device on a private network cannot
obtain a publicly trusted certificate, and a certificate warning on first use would teach
non-technical users to click through warnings. The dashboard is firewalled off from the upstream
network, clients on the access point are isolated from each other, and the WiFi itself is WPA2.
HTTPS with PrivacyPi's own certificate authority is available for users who install the root
certificate ("Trust this device"), and two-step login is optional. Someone who knows the WiFi
passphrase and can capture radio traffic could still observe an HTTP login.

### Known gaps

These are known and do not need a private report; fixes are welcome as normal pull requests.

- `vpn-write.sh auth`, `backup-create.sh` and `backup-restore.sh` receive passwords as command-line
  arguments, visible to other local processes for a moment.
- Saved VPN credentials are stored unencrypted on the SD card (root-only file permissions).
- Public DNS-over-HTTPS endpoints are not blocked by default.
