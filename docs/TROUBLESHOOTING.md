# Troubleshooting

Each entry lists what you see, the likely causes, and what to do. Start with the first fix in each
list. For normal use, see [USER-GUIDE.md](USER-GUIDE.md).

Two tools help with almost every problem:

- **The health report** `privacypi-status.txt` on the SD card. See
  [Reading privacypi-status.txt](#reading-privacypi-statustxt).
- **The rescue file** `privacypi-config.txt` on the SD card. See
  [The rescue file](#the-rescue-file-privacypi-configtxt).

## Contents

- [The setup WiFi "PrivacyPi-Setup" does not appear](#the-setup-wifi-privacypi-setup-does-not-appear)
- [The setup page does not open](#the-setup-page-does-not-open)
- [My own WiFi does not appear after pressing Finish](#my-own-wifi-does-not-appear-after-pressing-finish)
- [No internet after setup](#no-internet-after-setup)
- [The Pi will not join my home WiFi](#the-pi-will-not-join-my-home-wifi)
- [The VPN will not connect](#the-vpn-will-not-connect)
- [.onion sites do not open](#onion-sites-do-not-open)
- [I cannot open the dashboard](#i-cannot-open-the-dashboard)
- [I forgot the dashboard password](#i-forgot-the-dashboard-password)
- [I forgot the WiFi password](#i-forgot-the-wifi-password)
- [The Pi seems frozen](#the-pi-seems-frozen)
- [Reading privacypi-status.txt](#reading-privacypi-statustxt)
- [The rescue file privacypi-config.txt](#the-rescue-file-privacypi-configtxt)
- [Asking for help](#asking-for-help)

---

## The setup WiFi "PrivacyPi-Setup" does not appear

| Likely cause | What to do |
|---|---|
| The first start is still running. | Wait a full 2 to 3 minutes after plugging in the power. |
| Setup was already completed. | The Pi now broadcasts the WiFi name you chose, not `PrivacyPi-Setup`. Look for that name. |
| The card was not written correctly, or OS customisation was applied in Raspberry Pi Imager. | Flash the card again. Pick **Use custom**, and answer **No** to OS customisation. |
| Wrong Pi model. | The image is for Raspberry Pi 4 and Pi 5 only. |
| Weak power supply. | Use the official power supply for your Pi model. |
| You are too far away. | The network is on the 2.4 GHz band. Stand near the Pi for setup. |

Still nothing? Unplug the power, put the card in a computer and open `privacypi-status.txt` on the
`bootfs` drive.

- If the file **does not exist**, the Pi never finished starting. Flash the card again.
- If it exists, look at the top for `setup: PENDING`, at the `services` section for the `hostapd`
  line (it should say `active`), and at `roles` for `AP_IFACE=` (it should name a WiFi device such as
  `wlan0`). An empty `AP_IFACE` means the Pi found no WiFi radio that can broadcast a network.

## The setup page does not open

You are connected to `PrivacyPi-Setup` but no page pops up.

1. Open a browser and type **http://10.10.10.1** in the address bar. Type `http://`, not `https://`.
2. If your phone warns "this network has no internet", choose to **stay connected**. The setup
   network has no internet on purpose.
3. Switch off **mobile data** for a moment. Many phones send everything over mobile data when a WiFi
   network has no internet.
4. Switch off any VPN app on the phone, and "Private DNS" on Android, for the duration of setup.
5. Try another device, such as a laptop.

The automatic pop-up worked in our tests with the same checks phones use, but on one real Android
phone it did not appear and the address had to be typed. A fix for the suspected cause is included
in this release and has not been re-tested on that phone.

## My own WiFi does not appear after pressing Finish

- Wait. The Pi restarts completely; allow at least a minute, sometimes two.
- Your phone may still be trying to rejoin `PrivacyPi-Setup`, which no longer exists. Open the WiFi
  list and refresh it.
- If nothing appears after 5 minutes, unplug the power, wait 10 seconds and plug it back in.
- If the setup network comes back instead, the last wizard step did not complete. Run the wizard again.

## No internet after setup

Your devices join your PrivacyPi WiFi but websites do not load.

Open the dashboard (http://10.10.10.1) first. It works even when the internet does not.

| Check | What to do |
|---|---|
| **Dashboard** page says the internet is blocked (kill switch). | **Privacy mode** → choose the direct (no VPN) option. |
| A VPN is selected but not connected. With a VPN, devices are blocked whenever the tunnel is down. This is deliberate. | Wait a minute for it to reconnect, or open **VPN** → **Disconnect VPN** to go back to a direct connection. |
| Tor mode was just switched on. | Tor needs up to a minute to connect. Then try again. |
| **Internet & WiFi** page shows no connection. | Check that the network cable goes from the Pi to a LAN port on your router and clicks in at both ends. The Pi notices a newly plugged cable within a few seconds. |
| You use a USB WiFi adapter and it was plugged in after power-on. | Restart the Pi with the adapter plugged in. |
| The Pi switched from WiFi back to cable. | If joining your home WiFi failed, the Pi falls back to the cable. Re-enter the home WiFi password on the **Internet & WiFi** page. |
| Your home router also hands out `10.10.10.x` addresses. | PrivacyPi uses `10.10.10.x` for its own WiFi. Two networks with the same addresses clash. Change the address range on your home router. |
| Websites load but ads are not blocked in the first minutes. | The block lists are downloaded after the Pi first gets internet. Give it a few minutes. |

If only one app or site fails while others work, it may be blocked by the ad/tracker filter.
You can pick a lighter blocking level on the **DNS & ad blocking** page; see also
[FAQ.md](FAQ.md#can-i-see-or-change-what-is-blocked).

## The Pi will not join my home WiFi

| What you see | Cause and fix |
|---|---|
| The home-WiFi box is missing in the wizard, or the Internet & WiFi page says WiFi is not available on this PrivacyPi yet. | No USB WiFi adapter was detected. Plug one in and restart the Pi. The adapter must be present at power-on. |
| "WiFi failed to connect … rolled back to ethernet" | Wrong password, the network is out of range, or it gave no internet within about 25 seconds. Check the password and move the Pi closer to your router. |
| "WiFi passwords are 8–63 characters." | Networks without a password, or with a shorter one, cannot be joined in this release. |
| The network needs you to accept a web page first (hotel, café). | Not supported in this release. Use a cable, or a phone hotspot with a password. |
| You used the SD-card preset (`wifi_ssid=` …) and it did nothing. | Check `privacypi-status.txt`: under `journal: privacypi-init` a line says either that the preset was applied or that there is no spare WiFi radio. Check for typing mistakes: the password must be at least 8 characters and the `#` must be removed from each line. |

## The VPN will not connect

The dashboard shows a message when connecting fails. After a failed attempt PrivacyPi puts the
previous mode back, so your devices keep their internet.

| Message | Cause and fix |
|---|---|
| "Save your NordVPN service credentials first…" | Nothing saved yet. Enter the credentials, save them, then press **Connect**. |
| "The VPN provider rejected the username or password." | The most common mistake: using your **email login**. For NordVPN you need the **service credentials** from Nord Account → NordVPN → Manual setup. For other providers use the **manual configuration** username and password from their website. Copy and paste them to avoid typing errors. |
| "Could not get a server from NordVPN. Is the internet connected?" | The Pi has no working internet, or cannot reach NordVPN's server list. Check **Internet & WiFi** first, then try again. |
| "Could not download the NordVPN server config." | Same as above: check the internet connection and retry. |
| "No server file. Upload an .ovpn file for this provider first." | For providers other than NordVPN you must upload a configuration file from your provider. |
| "Save the username and password for this provider first." | The uploaded OpenVPN file needs a login. Enter the manual-configuration username and password and save them. |
| "That file does not look like an OpenVPN config…" / "…a WireGuard config." | Wrong file. Download the `.ovpn` or `.conf` file again from your provider. |
| "This OpenVPN config file is not accepted: …" | The file contains an option the Pi's OpenVPN does not understand. Try a different server file from your provider, and report the message. |
| "Could not connect to the VPN server (timed out)…" | The server did not answer. Try another server or country. Some networks block VPN connections; try a file marked "TCP" if your provider offers one. |

Other points:

- **ExpressVPN and providers other than NordVPN have not been verified with a real account in this
  release.** If your provider fails with a correct login and file, it may be a PrivacyPi problem.
  Please report it (see [Asking for help](#asking-for-help)).
- Connecting takes up to a minute. Do not press Connect repeatedly.
- "Connected, but no internet": while a VPN is selected, devices are blocked whenever the tunnel is
  down. Press **Disconnect VPN** to return to a direct connection.

## .onion sites do not open

First make sure Tor mode is on (**Privacy mode** → **Tor**) and https://check.torproject.org says you are
using Tor. Normal sites must work through Tor before `.onion` sites can.

If normal sites work but `.onion` addresses do not, your browser or phone is using its own DNS, or
refuses `.onion` names:

| Where | Fix |
|---|---|
| Chrome, Edge, Brave | Settings → Privacy and security → Security → turn **off** "Use secure DNS". |
| Android | Settings → Network & internet → **Private DNS** → Off. |
| Firefox | Open `about:config`, set `network.dns.blockDotOnion` to `false`. Also turn off "DNS over HTTPS" in the privacy settings. |
| A VPN or "private relay" app on the device itself | Switch it off while using PrivacyPi's Tor mode. |

Then close and reopen the browser.

## I cannot open the dashboard

- Are you on your **PrivacyPi WiFi**? The dashboard is not reachable from your home WiFi or from
  mobile data.
- Use **http://10.10.10.1**. If `privacypi.local` does not work on your device, the number always does.
- Type `http://`. Some browsers change it to `https://` and then show a certificate warning. That
  warning is expected unless you installed the certificate from the **Trust this device** page.
- "Too many failed attempts": after 5 wrong passwords, sign-in from your device is blocked for
  15 minutes.
- Switch off mobile data and any VPN app on the device and try again.

## I forgot the dashboard password

There is no password recovery. Do a factory reset from the SD card:

1. Unplug the Pi. Put the SD card in a computer and open the `bootfs` drive.
2. In `privacypi-config.txt`, remove the `#` in front of `reset=yes`. Save.
3. Put the card back and power on. After about 2 minutes, join `PrivacyPi-Setup` (password
   `privacypi`) and run the wizard again.

The same applies if you lost the authenticator app used for two-step login.

## I forgot the WiFi password

**If any device is still connected** to the PrivacyPi WiFi: open the dashboard on it, go to
**Internet & WiFi**, and set a new WiFi name and password.

**If no device is connected**, pick one:

- Do a factory reset from the SD card (steps above). Simple, but you set everything up again.
- Or keep your settings: in `privacypi-config.txt` on the SD card, remove the `#` in front of
  `admin_on_wan=yes`. After the next start the dashboard can also be opened from your **home
  network**, at the address your home router gave the Pi (look it up in your router's device list).
  Sign in, set a new WiFi password on the **Internet & WiFi** page, then change the line to
  `admin_on_wan=no` and restart, so the dashboard is hidden from the home network again.

## The Pi seems frozen

The WiFi has disappeared, or nothing responds.

1. **Wait first.** A restart, the first start and the step after Finish each take one to two minutes,
   and the WiFi is gone during that time.
2. Unplug the power, wait 10 seconds, plug it back in. Wait 2 minutes.
3. If it freezes repeatedly, check the power supply and try another SD card.
4. Check which radio is broadcasting. PrivacyPi always uses the Pi's built-in WiFi for your private
   network. A USB adapter should only be used to join your home WiFi. In testing, one USB adapter
   (Edimax EW-7811Un) froze the whole Pi when it was used to broadcast the network. If the report
   shows your USB adapter as `AP_IFACE`, the built-in WiFi was not found; remove the adapter, use a
   cable, and report it.
5. Read `privacypi-status.txt` (next section) and look at `failed units` and
   `journal: errors this boot`.

## Reading privacypi-status.txt

The Pi writes this plain-text report to the `bootfs` drive of the SD card about 75 seconds after
every start, then once an hour, and once more when the wizard finishes. To read it: unplug the Pi,
put the card in a computer, open the `bootfs` drive, open the file in a text editor.

If the file's `generated:` time is old, the Pi did not get far enough during its last start to
write a new one.

| Section | What it tells you |
|---|---|
| Top lines | Version, Pi model, and `setup: complete` or `setup: PENDING`. |
| `roles (site.conf)` | `AP_IFACE` = radio broadcasting your WiFi. `WIFI_WAN_IFACE` = spare radio (USB adapter); empty if there is none. `WAN_MODE` = `ethernet` or `wifi`. `AP_SSID` = your WiFi name. |
| `services` | One line per part of the system: name, state, and whether it starts automatically. After setup, expect `active` for `hostapd`, `dnsmasq`, `unbound`, `AdGuardHome`, `caddy`, `privacypi-flask`. `privacypi-setup-mode` and `privacypi-setup-dns` are active only before setup is finished. `ssh` and `privacypi-openvpn` are normally `inactive`. |
| `failed units` | Should be empty. Anything listed here is worth reporting. |
| `interfaces` | Addresses. `br-vlan10` should show `10.10.10.1`. Your uplink (`eth0` or the USB radio) should show an address from your home router. No address there means no internet. |
| `routes` | A line starting with `default` under `table 100` means your devices have a way out to the internet. |
| `wifi radios (bus / AP support)` | One line per radio. `bus=sdio` is the built-in radio, `bus=usb` an adapter. |
| `hostapd.conf (password hidden)` | Your WiFi settings, with the password replaced by `<hidden>`. |
| `journal: …` | The last log lines of each part, and the most recent errors. |

## The rescue file privacypi-config.txt

This file sits next to the status report on the `bootfs` drive. Edit it in a plain text editor.
A line starting with `#` is switched off. Remove the `#` to switch it on.

| Line | Effect |
|---|---|
| `reset=yes` | Factory reset on the next start. Applied once. |
| `wifi_ssid=` / `wifi_password=` / `wifi_country=` | Join this home WiFi (needs a USB WiFi adapter). The password line is removed once applied. |
| `admin_on_wan=yes` | Make the dashboard reachable from the home network too. Stays on until you set `admin_on_wan=no`. Leave it off unless you need it. |
| `ssh_password=…` | For developers: enables remote login (SSH) for user `pi` with this password. The line is removed once applied, but SSH stays enabled until a re-flash. Do not use this unless you know why you need it. |

## Asking for help

Open an issue on the project's GitHub page and include:

1. `privacypi-status.txt` from the SD card.
2. Your Pi model (4 or 5) and, if you use one, the make and model of your USB WiFi adapter.
3. How the Pi gets internet: cable or home WiFi.
4. What you did, what you expected, and what happened instead. Include the exact text of any message.
5. For VPN problems: the provider and whether you used OpenVPN or WireGuard. **Never post your VPN
   username, password or configuration file.**

The status file contains no passwords or keys. It does contain your WiFi name and may contain the
names and hardware addresses of devices on your network. Read through it before posting publicly and
remove anything you prefer to keep private.

Security problems should not be reported in public issues. See [SECURITY.md](../SECURITY.md).
