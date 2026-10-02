# Frequently asked questions

Short, honest answers about PrivacyPi 2.6.0. For step-by-step instructions see
[USER-GUIDE.md](USER-GUIDE.md); for problems see [TROUBLESHOOTING.md](TROUBLESHOOTING.md).

## What it does and does not do

### What does PrivacyPi protect against?

- **Your internet provider watching which sites you visit** — when you use a VPN or Tor. Without
  them, your provider no longer sees your DNS lookups, but still sees which servers you connect to.
- **DNS snooping.** Lookups are filtered on the Pi and sent on encrypted.
- **Ad and tracker profiling**, by blocking known ad, tracker and malware domains for every device.
- **Untrusted networks** such as hotel or café WiFi, when the Pi sits between that network and
  your devices.
- **Censorship**, to the extent that your VPN or Tor gets around it.

### What does it not protect against?

- **A device that is already compromised.** Malware on your laptop sees everything you do.
- **Browser fingerprinting and logins.** If you sign in to an account, that service knows it is you,
  VPN or not.
- **A dishonest VPN provider.** With a VPN you move your trust from your internet provider to the
  VPN company.
- **Someone with physical access to the Pi.** The SD card is not encrypted. Saved VPN logins and
  your WiFi password can be read from it.
- **Legal orders** served on you or your VPN provider.

PrivacyPi improves privacy. It does not make you anonymous by itself.

### Is every device on my WiFi protected the same way?

All devices on the PrivacyPi WiFi share the same mode (Direct, VPN, Tor…). Two limits:

- Ad blocking works on DNS lookups. Apps or browsers that use their own encrypted DNS (for example
  Chrome's "Use secure DNS") bypass the blocker by default. Ordinary DNS is always forced through
  the Pi.
- In **Tor mode** the ad blocker is not applied; lookups go straight to Tor.

### Does it block ads inside YouTube or apps?

Only where the ads come from separate, known ad domains. Ads served from the same servers as the
content (YouTube is the usual example) cannot be blocked by DNS filtering.

## Privacy of PrivacyPi itself

### Does it log my browsing?

Partly, and only on the device:

- The built-in ad blocker (AdGuard Home) keeps a **query log for 24 hours**: which device looked up
  which domain name. It is stored on the SD card and feeds the statistics on the Dashboard page.
  Statistics are also kept for 24 hours.
- It records **domain names only** — never page addresses, page content or passwords.
- The DNS resolver behind it (Unbound) logs nothing.
- The dashboard keeps an **audit log** of settings changes (who changed what, when).
- The system log notes when devices join and get an address. It is capped in size.

Nothing is uploaded to the PrivacyPi project. There is no telemetry and no account.

### What does the Pi itself contact on the internet?

- **Cloudflare (1.1.1.1) and Quad9 (9.9.9.9)** for DNS, over an encrypted connection. They see the
  lookups, though not which device in your home made them. While a VPN is on, the same resolvers are
  reached through the VPN tunnel.
- **Block-list sources** (AdGuard's filter list and the StevenBlack hosts list), to download updates.
- **Cloudflare's time servers**, to set the clock.
- **api.ipify.org**, to show your public IP address on the Dashboard page.
- **NordVPN's server list and config download**, only if you use the NordVPN connect button.
- **Software package servers**, only if you install an Extra.

The dashboard pages load nothing from outside the Pi.

### Is it safe that the dashboard uses http:// and not https://?

It is a deliberate trade-off. A device on your home network cannot get a normal web certificate, so
`https://` would show a scary warning to everyone. Plain HTTP avoids that.

What protects you:

- The dashboard is only reachable from your own PrivacyPi WiFi, which is encrypted (WPA2) and needs
  your WiFi password. It is closed to the home network and the internet.
- Devices on the PrivacyPi WiFi are isolated from each other.

What remains: someone who knows your WiFi password and is within radio range could, with effort,
capture your dashboard password as you type it. If that worries you:

- Use the **Trust this device** page to install PrivacyPi's certificate, then use `https://10.10.10.1`.
- Turn on two-step login on the **System & password** page.
- Do not give the PrivacyPi WiFi password to people you do not trust.

### The setup password "privacypi" is public. Is that a problem?

No. During setup the `PrivacyPi-Setup` network gives access to the setup page only, with no internet
and nothing to steal: the device has no settings yet. The risk is that someone nearby completes the
wizard before you do. You would notice immediately, because the password you choose would not work.
A factory reset from the SD card undoes it. Finish the wizard soon after the first start.

### Can I see or change what is blocked?

Yes, at two levels.

- The **DNS & ad blocking** page offers four blocking levels: Light (ads and trackers), Standard
  (adds known dangerous sites), Strict (adds phishing and malware checks) and Family (adds
  adult-content blocking and safe search). The choice applies to every device.
- The blocker (AdGuard Home) also has its own control panel, linked from the same page, for allowing
  a single site or adding lists. It has a separate sign-in (user `admin`) with a random password
  created on the first start. The dashboard does not show that password in this release; it is
  stored on the device and reachable only with developer access.

## Hardware

### Which Raspberry Pi models work?

Raspberry Pi 4 and Raspberry Pi 5. The image is 64-bit. The hardware test for this release was run
on a Pi 4.

### Which USB WiFi adapters work?

The adapter is only used to **join** your home WiFi, which is the simple case that most
Linux-supported adapters handle. The one tested for this release is the **Edimax EW-7811Un**. Other
adapters are untested; reports are welcome.

### Do I need a USB WiFi adapter?

Only if you cannot run a network cable from the Pi to your router. The built-in WiFi broadcasts your
private network and cannot join your home WiFi at the same time.

### Can the USB adapter broadcast the WiFi instead, for better range?

No. PrivacyPi always uses the built-in WiFi for your private network. The tested Edimax adapter
froze the whole Pi when used as the access point.

### Can I connect devices by cable?

No. The Pi's network socket is its connection *to* the internet. Devices join over WiFi.

### How many devices, and what range?

Not measured. Expect the range of a small 2.4 GHz access point: fine for a room or a small flat,
not a whole house. 5 GHz is not available in this release.

## Speed

### How fast is it?

We have not published measurements, so no numbers here. What to expect:

- **Direct mode:** limited by the Pi's 2.4 GHz WiFi, not by filtering.
- **VPN:** slower than Direct. The Pi has to encrypt everything, and the VPN server adds distance.
- **Tor:** much slower. Good for reading, poor for video.

Measure it yourself: the **Troubleshooting** page in the dashboard has a speed test that measures
the current route.

## Everyday use

### Can I use it while travelling?

Yes, with limits. With a USB WiFi adapter the Pi can join another WiFi and give you your own private
network on top. In this release it can only join networks that have a normal password. It cannot
join open networks or networks that first show a login page, which rules out many hotels. A network
cable or a phone hotspot works.

The **Use it away from home** page is a different idea (connecting back to your Pi at home while you are
away). It was not re-tested for this release.

### Can I use a VPN and Tor together?

No. You choose one route at a time on the **Privacy mode** page.

### Which VPN providers work?

- **NordVPN:** tested on a real device.
- **Any provider that gives you a standard OpenVPN file with a username and password:** the
  mechanism passed automated tests against a standard OpenVPN server, but individual providers
  (ExpressVPN, Surfshark, Proton VPN, Mullvad and the others listed on the page) have **not been
  verified with real accounts**.
- **WireGuard `.conf` files:** implemented, not covered by the automated tests.

### Do my devices need a VPN app?

No. The Pi runs the VPN. Running a VPN app on a device as well is unnecessary and can cause problems.

### What happens when the VPN drops?

Your devices lose internet until the Pi reconnects, which it does by itself. They never fall back to
your normal connection silently.

### Why can't my phone find my printer or TV?

Devices on the PrivacyPi WiFi are isolated from each other, and they are on a different network from
devices on your home WiFi. Casting and wireless printing between them will not work.

### Does it support IPv6?

No. IPv6 is switched off on the PrivacyPi WiFi so that traffic cannot slip around the VPN or Tor.
Everything works over IPv4.

### Can I have a guest network, or different rules for different devices?

Not in this release. There is one network with one mode. (The Devices page shows per-device routing
from an older version; it was not re-tested.)

### How do I update?

Flash the new image and run the wizard again. There is no over-the-air update yet. See
[USER-GUIDE.md](USER-GUIDE.md#16-updating).

### How do I switch it off?

Unplug it. There is no shut-down button in this release. See
[USER-GUIDE.md](USER-GUIDE.md#15-lights-start-up-time-and-switching-off) for when not to unplug.

### Some pages in the dashboard do nothing. Why?

A few features from older versions still have pages or buttons but their background parts are not
switched on in this release: anomaly detection, alert rules, the daily digest, schedules and
per-domain routing. They are listed in [STATUS.md](../STATUS.md).

### Is this finished software?

No. Version 2.6.0 is a pre-release. The core path — flash, wizard, private WiFi, ad blocking, NordVPN,
Tor — was tested on one real Pi 4. Other parts are marked as untested throughout these docs.
