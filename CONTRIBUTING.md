# Contributing to PrivacyPi

Thank you for helping. PrivacyPi is meant to be usable by people who have never opened a terminal,
so the most valuable contributions are the ones that keep it that way: hardware test reports, fixes
for things that confused you, and clear wording.

Read [docs/DEVELOPER.md](docs/DEVELOPER.md) first. It explains the architecture, the build and the
pitfalls already found. [STATUS.md](STATUS.md) lists what is done, what is untested and what is
deliberately not in this release.

## Ways to contribute

- **Test on real hardware** and report what happened: Pi model, USB WiFi adapter model, phone or
  laptop used for setup, VPN provider. Attach `privacypi-status.txt` from the SD card's `bootfs`
  partition (no passwords inside; check it for your WiFi name and device names before posting).
  Reports for ExpressVPN and other providers, for other WiFi adapters and for the Pi 5 are
  especially useful, because those are not yet verified.
- **Report a bug** as a GitHub issue. See
  [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md#asking-for-help) for what to include.
- **Report a security problem privately**, not as an issue. See [SECURITY.md](SECURITY.md).
- **Send a pull request.**

## Setting up

You need Docker and a clone of the repository. Nothing else is required to build and test.

```bash
git clone <this-repo> privacypi && cd privacypi
tests/e2e.sh            # boots the installed system in a container and walks through the whole journey
```

To work against a real Pi without reflashing, use the SSH option in `privacypi-config.txt` and
`tools/dev-push.sh <pi-address>`. Details are in
[docs/DEVELOPER.md](docs/DEVELOPER.md#the-fast-development-loop).

## Before you open a pull request

1. Run the tests that apply:

   ```bash
   tests/e2e.sh
   docker run --rm -v "$PWD":/repo:ro debian:trixie-slim bash -c \
     "mkdir -p /opt/privacypi && cp -r /repo/opt/privacypi/scripts /opt/privacypi/ && bash /repo/tests/test-net-roles.sh"
   ```

   If you changed `install.sh`, the image build or anything that could differ on Raspberry Pi OS,
   also run `./build-image.sh && tests/e2e-image.sh`.
2. Add or extend a check in `tests/e2e.sh` for the behaviour you changed.
3. If the change touches radios, hostapd, drivers or boot timing, say in the pull request whether
   you tested it on a real Pi, and on which hardware. The container tests cannot cover those.
4. Update the docs in `docs/` if behaviour or wording that users see has changed.

## Rules of the road

- **Keep the layman path intact.** Flash, power on, join `PrivacyPi-Setup`, finish the wizard. No
  step may require a terminal, SSH or a monitor.
- **Nothing device-specific in the image.** Secrets are generated on first boot. The image build
  fails if any are left behind; do not weaken that check.
- **No hardcoded interfaces, subnets or ports** in scripts. Use `lib/site.sh`.
- **The built-in radio is the access point.** Do not add paths that put the AP on a USB adapter.
- **Privileged work goes through the allow-list.** A new privileged script needs an entry in
  `config.py`, in the sudoers file, and possibly in the dashboard unit's `ReadWritePaths`. See
  [docs/DEVELOPER.md](docs/DEVELOPER.md#adding-a-privileged-script).
- **Secrets travel on stdin**, never in arguments, logs, the audit log or the status report.
- **No external resources** in dashboard pages.
- **Do not enable untested background features.** Leave the unit disabled and list it in `STATUS.md`.
- **Say what was verified.** If something is implemented but not tested with real hardware or a real
  account, write that in the code comment, the pull request and the docs.
- Error messages shown to users are plain language and say what to do next.

## Pull requests

- Branch from `main`. One topic per pull request.
- Commit subjects follow the existing style: `fix: …`, `feat: …`, `docs: …`.
- Describe what changed, why, and how you tested it (container tests, real hardware, or neither).
- Do not commit build output (`build/`), screenshots, credentials or local notes. `.gitignore`
  already excludes them.

Files under `docs/history`, `docs/superpowers` and `docs/ops` are a historical record of an older
version. Please leave them as they are.
