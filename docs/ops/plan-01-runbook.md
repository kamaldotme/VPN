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
