# PrivacyPi user guide

This guide is for people who want to use PrivacyPi, not develop it. No terminal, keyboard or screen
is needed on the Raspberry Pi.

PrivacyPi turns a Raspberry Pi into a private WiFi network. Every phone, laptop or TV that joins that
WiFi gets ads and trackers blocked and its DNS lookups encrypted (DNS is the "phone book" your device
uses to find websites). If you want, all traffic can also go through your VPN or through Tor.

Version covered: **2.6.0** (pre-release). If something goes wrong, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md). Common questions are in [FAQ.md](FAQ.md).

## Contents

1. [What you need](#1-what-you-need)
2. [Put PrivacyPi on the SD card](#2-put-privacypi-on-the-sd-card)
3. [First start](#3-first-start)
4. [The setup wizard, screen by screen](#4-the-setup-wizard-screen-by-screen)
5. [Using your home WiFi instead of a cable](#5-using-your-home-wifi-instead-of-a-cable)
6. [Joining your devices](#6-joining-your-devices)
7. [The dashboard](#7-the-dashboard)
8. [Adding a VPN](#8-adding-a-vpn)
9. [Tor and .onion sites](#9-tor-and-onion-sites)
10. [Changing the WiFi name or password](#10-changing-the-wifi-name-or-password)
11. [The kill switch](#11-the-kill-switch)
12. [Two-step login (optional)](#12-two-step-login-optional)
13. [Backup and restore](#13-backup-and-restore)
14. [Factory reset](#14-factory-reset)
15. [Lights, start-up time and switching off](#15-lights-start-up-time-and-switching-off)
16. [Updating](#16-updating)

---

## 1. What you need

- A **Raspberry Pi 4 or Raspberry Pi 5** with its power supply.
  (The hardware test for this release was done on a Pi 4.)
- A **microSD card**, 8 GB or larger, and a way to plug it into your computer.
- A way to give the Pi internet. Pick one:
  - **A network cable** from the Pi to your home router. This is the simplest and most reliable.
  - **A USB WiFi adapter** plugged into the Pi. The Pi then joins your home WiFi and no cable is
    needed. See [section 5](#5-using-your-home-wifi-instead-of-a-cable).
- A phone or laptop to do the setup.
- Optional: a VPN subscription (for example NordVPN).

Why the adapter? The Pi's built-in WiFi is always busy broadcasting your private network. It cannot
join your home WiFi at the same time. A second radio (the USB adapter) does that job.

## 2. Put PrivacyPi on the SD card

"Flashing" means writing the PrivacyPi system onto the SD card.

1. Download the file `privacypi-2.6.0.img.xz` from the project's release page. Do not unpack it.
2. Install and open [Raspberry Pi Imager](https://www.raspberrypi.com/software/).
3. Choose your Pi model if Imager asks.
4. Under **Choose OS**, scroll down and pick **Use custom**. Select the file you downloaded.
5. Under **Choose Storage**, pick your SD card.
6. If Imager asks whether to apply OS customisation settings, answer **No**.
   PrivacyPi sets itself up. The Imager settings are not used.
7. Let it write and verify. Then remove the card.

balenaEtcher also works: select the file, select the card, flash.

## 3. First start

1. Put the SD card into the Pi.
2. Plug in the network cable (Pi to router). If you use a USB WiFi adapter instead, plug the adapter
   in now. **The adapter must be plugged in before you power on.**
3. Plug in the power.
4. Wait about **2 minutes**. The first start takes longer than later ones, because the Pi creates
   its own unique keys and passwords.
5. On your phone or laptop, open the WiFi list. Join **`PrivacyPi-Setup`**. The password is
   **`privacypi`**.
6. The setup page should open by itself (as a "sign in to network" page). If it does not, open a
   browser and go to **http://10.10.10.1**

While setup is not finished, the `PrivacyPi-Setup` network gives you the setup page only. It does not
give internet. Your phone may say "no internet" — that is expected. Stay connected.

## 4. The setup wizard, screen by screen

The wizard takes about two minutes.

### Welcome — your country

Pick your country and press **Get started**. The country decides which WiFi channels the Pi is
legally allowed to use. Your phone or laptop also quietly tells the Pi the current time on this
screen, because the Pi has no battery clock.

### Dashboard password

Choose a password of at least 8 characters and type it twice. You will need it later to change
settings. Write it down. The user name is always `admin`.

### Internet connection

The page shows whether the Pi has internet.

- **With a cable:** it should say it is connected via the network cable. Press **Continue**.
- **With a USB WiFi adapter:** a box for your home WiFi appears. Press **Find nearby networks**, tap
  your home WiFi, type its password, press **Connect to this WiFi**. This can take up to 30 seconds.
- **Not connected yet?** You can still continue and plug the cable in later.

If you have no USB adapter, the home-WiFi box is not shown. That is normal.

### Your private WiFi

Choose the name and password of your new private network. This replaces `PrivacyPi-Setup`.

- Name: 1 to 32 characters. Letters, numbers, spaces, dot, dash and underscore are allowed.
- Password: 8 to 63 characters. It cannot be `privacypi`.

### How private?

Pick one. You can change it later.

- **Ad-blocking + private DNS** — blocks ads and trackers and encrypts DNS lookups. Fastest. This is
  also the choice if you plan to add a VPN: you add the VPN from the dashboard after setup.
- **Tor** — sends everything through the Tor network. More anonymous, but slow, and some sites block
  it. See [section 9](#9-tor-and-onion-sites) first.

### Ready to go

Check the summary and press **Finish setup**. The Pi restarts. The `PrivacyPi-Setup` network disappears.
**About a minute later your own WiFi appears.** Join it with the WiFi password you just chose.

## 5. Using your home WiFi instead of a cable

You need a USB WiFi adapter. Plug it in **before** powering on. If you plug it in while the Pi is
running, restart the Pi.

There are three ways to tell the Pi about your home WiFi.

**In the wizard.** Use the Internet connection screen as described above.

**Later, in the dashboard.** Open **Internet & WiFi**, find the box for joining another WiFi
network, search for nearby networks, pick yours, enter the password and connect. If the password is wrong or the connection fails, the
Pi switches back to the cable by itself. You do not get locked out.

**Before the first start, on the SD card.** Useful when you have no cable at all.

1. Put the SD card in your computer. A small drive called `bootfs` appears.
2. Open the file `privacypi-config.txt` in a plain text editor.
3. Find these lines, remove the `#` at the start of each, and fill in your details:

   ```
   wifi_ssid=Your home WiFi name
   wifi_password=your-home-wifi-password
   wifi_country=IN
   ```

   `wifi_country` is your two-letter country code (for example `US`, `GB`, `DE`, `IN`).
4. Save, eject the card, put it in the Pi, power on.

After the Pi has used the password, it removes the password line from the file.

Limits in this release:

- Your home WiFi must have a password of 8 or more characters. Open networks, and networks that show
  a login page (many hotels and cafés), cannot be joined.
- Do not try to use the USB adapter to broadcast the private network. PrivacyPi always uses the
  built-in WiFi for that. One tested adapter (Edimax EW-7811Un) froze the Pi when used that way.

## 6. Joining your devices

On each device, open the WiFi settings, pick your new network and enter the WiFi password. Nothing
needs to be installed on the device.

Good to know:

- Devices on the PrivacyPi WiFi cannot see each other. This is a safety feature. It also means things
  like wireless printing or casting between two devices on this WiFi will not work.
- The network uses the 2.4 GHz band.
- Devices that stay on your old home WiFi are **not** protected. Only devices on the PrivacyPi WiFi are.

## 7. The dashboard

The dashboard is where you change settings.

- Address: **http://10.10.10.1** (or **http://privacypi.local**)
- User: **admin**
- Password: the dashboard password you chose in the wizard

You can only open it **while connected to your PrivacyPi WiFi**. It is not reachable from your home
network or from the internet (unless you deliberately switch that on, see
[TROUBLESHOOTING.md](TROUBLESHOOTING.md#i-forgot-the-wifi-password)).

After 5 wrong passwords the sign-in page locks for 15 minutes for that device.

The menu is grouped as shown below. Menu and button names are still being polished, so a label on
your screen may differ slightly from this guide. Go by the purpose.

### Home

| Page | What it is for |
|---|---|
| **Dashboard** | Shows at a glance whether you are protected (direct, via VPN, via Tor, or blocked), your public IP address, how much was blocked, and which devices are online. |
| **Internet & WiFi** | How the Pi reaches the internet: cable or another WiFi network. Also where you change the name and password of your own PrivacyPi WiFi. |
| **Devices** | Lists the devices that have joined your PrivacyPi WiFi. The page also offers a separate rule per device; that part comes from an older version and was not re-tested for this release. |

### Privacy

| Page | What it is for |
|---|---|
| **Privacy mode** | The main switch. Choose how every device reaches the internet: direct (no VPN), VPN (OpenVPN), VPN (WireGuard), Tor, Proxy, or block all internet. |
| **VPN** | Sign in to your VPN once and connect or disconnect it. See [section 8](#8-adding-a-vpn). |
| **Tor** | Extra Tor settings: bridges (for networks that block Tor) and sending DNS lookups through Tor. Most people never need them. |
| **Proxies** | For advanced users: save a proxy server (SOCKS5, Shadowsocks and similar) to use with the Proxy mode. Not re-tested for this release. |
| **DNS & ad blocking** | Choose how much is blocked (Light, Standard, Strict, Family), and open the built-in blocker's own control panel. |

### Tools

| Page | What it is for |
|---|---|
| **Use it away from home** | Lets your phone or laptop connect back to your PrivacyPi when you are away. Needs a setting on your home router (port forwarding). Not re-tested for this release. |
| **Trust this device** | Optional. Install PrivacyPi's certificate on a device so the dashboard can be opened with `https://` without a browser warning. |
| **Troubleshooting** | Simple checks run from the Pi (can a site be reached, can its name be found, which route it takes) and a speed test. |
| **Extras** | Install optional networks on demand: I2P, Yggdrasil, Lokinet. Needs internet. |
| **Backup & restore** | Download an encrypted copy of your settings, or restore one. See [section 13](#13-backup-and-restore). |

### Settings

| Page | What it is for |
|---|---|
| **System & password** | Device health (running time, workload, temperature), change the dashboard password, two-step login, restart, and factory reset. It also holds a few advanced options carried over from older versions that were not re-tested. |
| **Alerts** | Add places to send notifications. PrivacyPi does not send alerts automatically in this release, so do not rely on it. |
| **Activity log** | A record of the last 200 sign-ins and changes made in the dashboard. |

### Features that are present but not active

Some features from older versions still have screens or buttons, but the background parts that make
them work are switched off in this release: anomaly detection, alert rules, the daily digest,
schedules and per-domain routing. Their pages may load but stay idle. The update buttons on the
**System & password** page do not update PrivacyPi either; see [section 16](#16-updating).

## 8. Adding a VPN

A VPN sends all traffic from your PrivacyPi WiFi through your VPN provider. You sign in once on the
Pi. Your devices need no VPN app.

Open **VPN** in the dashboard menu.

### NordVPN

Tested and working on a real device, including reconnecting after a restart.

1. You need NordVPN's **service credentials**. These are **not** your email and password.
   Find them on the NordVPN website: Nord Account → NordVPN → **Manual setup**. You get a long
   username and a long password.
2. In the NordVPN box, enter that username and password and save them.
3. Pick a country, or leave **Fastest server (recommended)**.
4. Press **Connect**. This can take up to a minute.

### ExpressVPN and other providers

The steps below are implemented, but **have not yet been verified with a real ExpressVPN account**
(or any provider other than NordVPN). The same mechanism passed our tests against a standard
OpenVPN server. If it fails for your provider, please report it.

1. On your provider's website, find the **manual configuration** (sometimes "manual setup",
   "OpenVPN" or "router") page.
2. Copy the manual-configuration **username and password** shown there. These usually differ from
   your account login.
3. Download the configuration file for the server you want: an `.ovpn` file (OpenVPN) or a `.conf`
   file (WireGuard).
4. In the dashboard, find your provider's box (or **Custom OpenVPN** / **Custom WireGuard**).
5. Enter the username and password and save them. (WireGuard `.conf` files do not need this.)
6. Add the server file you downloaded.
7. Press **Connect**.

### While the VPN is on

- The Dashboard page shows that you are protected, and your public IP address changes.
- **If the VPN drops, your devices lose internet instead of quietly continuing without it.**
  The Pi reconnects by itself.
- After a restart the VPN comes back by itself.
- To stop using the VPN, press **Disconnect VPN** on the VPN page. You go back to a direct
  connection (no VPN).
- On the **Privacy mode** page, the two VPN options (OpenVPN and WireGuard) reconnect the VPN you
  used last.

## 9. Tor and .onion sites

Tor hides where your traffic comes from by bouncing it through several volunteer computers.

To switch it on: **Privacy mode** → **Tor**. The first connection can take a minute. To check, open
https://check.torproject.org on a device on your PrivacyPi WiFi.

What to expect:

- It is slow. Video and large downloads are painful.
- Some websites block Tor or show extra "are you human" checks.
- Only normal web-style traffic (TCP) goes through. Some apps, such as certain video-call and game
  apps, will not work in Tor mode.
- The ad and tracker blocker is not applied in Tor mode: lookups go straight to Tor.
- Tor hides your address. It does not stop websites recognising your browser. For serious anonymity
  the Tor Project's own Tor Browser offers protections a normal browser does not.

### Opening .onion sites

In Tor mode, devices on your WiFi can open `.onion` addresses in a normal browser. This was tested
and works. But some browsers get in the way, because they refuse `.onion` names or use their own
DNS instead of the Pi's. If an `.onion` site does not open:

| Where | What to change |
|---|---|
| Chrome, Edge, Brave | Settings → Privacy and security → Security → turn **off** "Use secure DNS". |
| Android (whole phone) | Settings → Network & internet → **Private DNS** → Off. |
| Firefox | Firefox blocks `.onion` by default. Type `about:config` in the address bar, search for `network.dns.blockDotOnion`, set it to `false`. Also switch off "DNS over HTTPS" in Firefox's privacy settings. |

To leave Tor mode: **Privacy mode** → choose the direct (no VPN) option.

## 10. Changing the WiFi name or password

1. Open **Internet & WiFi** in the dashboard.
2. In the box about your PrivacyPi WiFi, type the WiFi name and a new password (8 or more characters).
3. Press **Save and restart WiFi**.

The WiFi restarts a few seconds later. Every device, including the one you are using, has to join
again with the new details.

To change the **dashboard** password instead: open **System & password**. Other devices that
were signed in to the dashboard are signed out.

## 11. The kill switch

There are two kinds.

**Automatic, with a VPN.** While a VPN is on, devices can only reach the internet through the VPN.
If the VPN connection breaks, they have no internet until it is back. Nothing to switch on.

**Manual.** **Privacy mode** → **Block all internet** cuts internet for every device on your
PrivacyPi WiFi at once. The dashboard stays reachable. It stays on, even after a restart, until you
choose another option (for example the direct, no-VPN one) on the same page.

## 12. Two-step login (optional)

With two-step login the dashboard asks for your password and a 6-digit code from an authenticator
app on your phone (Google Authenticator, Authy, 1Password and similar).

1. Open **System & password**.
2. In the two-step login box, turn it on.
3. Scan the QR code with your authenticator app.
4. Type the 6-digit code the app shows and confirm.

To switch it off, use the same box. It asks for your dashboard password.

If you lose the phone with the authenticator app, the only way back in is a factory reset.

## 13. Backup and restore

A backup is one encrypted file holding your PrivacyPi settings, including saved VPN logins.

**Download:** open **Backup & restore**, type your dashboard password, press **Download backup**. Keep the file
somewhere safe. It is encrypted with your dashboard password, so you need that same password to
restore it.

**Restore:** open **Backup & restore**, choose the file, type the password it was made with, and
restore. This overwrites the current settings. Restart the Pi afterwards (from **System & password**)
so everything, including the WiFi name, is applied.

Notes:

- The password of your *home* WiFi (when the Pi uses a USB adapter) is not part of the backup. Enter
  it again on the **Internet & WiFi** page.
- Restore is not covered by this release's automated tests. Treat a backup as a convenience, and
  keep your VPN details and passwords written down as well.

## 14. Factory reset

A factory reset erases **everything**: passwords, WiFi name, VPN logins, all settings. The Pi then
starts again with `PrivacyPi-Setup` and the wizard, as on the first day.

### From the dashboard

**System & password** → **Factory reset** → confirm. The Pi restarts by itself.

### From the SD card (when you are locked out)

Use this if you forgot the dashboard password or the WiFi password.

1. Unplug the Pi's power. Take out the SD card and put it in a computer.
2. Open the small drive called `bootfs`.
3. Open `privacypi-config.txt` in a plain text editor.
4. Find the line `#reset=yes` and remove the `#`, so it reads `reset=yes`.
5. Save, eject the card, put it back in the Pi, power on.
6. Wait about 2 minutes, then join `PrivacyPi-Setup` (password `privacypi`) and run the wizard again.

The reset happens once. The Pi marks the line as done so it does not repeat.

## 15. Lights, start-up time and switching off

**Start-up time**

- First start after flashing: about 2 minutes until `PrivacyPi-Setup` appears.
- After pressing Finish in the wizard: about 1 minute until your own WiFi appears.
- Normal restarts: allow about a minute.

**Lights.** PrivacyPi does not use the Pi's lights for its own signals. They behave as on any
Raspberry Pi: one light shows power, and the green light flickers while the Pi reads or writes the SD
card, which is mostly during start-up. No light pattern tells you "ready". The sign that it is ready
is that the WiFi appears.

**No screen needed.** The Pi writes a health report called `privacypi-status.txt` to the `bootfs`
drive of the SD card about a minute after each start, and then every hour. It contains no passwords.
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md#reading-privacypi-statustxt).

**Restarting.** **System & password** → restart the device. The restart begins after a one-minute
delay.

**Switching off.** This release has no "shut down" button. To switch the Pi off, unplug the power.
To keep the SD card healthy, avoid unplugging:

- during the first start (the first 2 minutes after flashing),
- in the minute after pressing Finish, saving settings, or starting a factory reset,
- while an Extra is being installed.

PrivacyPi can stay on all the time. That is how it is meant to be used.

## 16. Updating

There is no over-the-air update yet. The update buttons on the **System & password** page are a leftover and do
not install new versions.

To update, flash the new image onto the SD card ([section 2](#2-put-privacypi-on-the-sd-card)) and
run the wizard again. Flashing erases the card, so note your VPN details first. You can download a
backup beforehand, but restoring a backup made on a different version has not been tested.
