# Running a Python web app on a Raspberry Pi as a service (any app in this repo)

How to make an app in this repo start by itself on a Raspberry Pi, restart if
it crashes, and be reachable from other devices. Piackereső's
`piackereso/install-pi.sh` is a working example to copy from; app docs link
here and keep only what is specific to the app.

## Assumptions

- **64-bit Raspberry Pi OS** (Bookworm or later). Compiled wheels (Pillow,
  cffi, curl_cffi, …) exist for `aarch64` on PyPI and piwheels; on 32-bit
  `armv7l` some (e.g. curl_cffi) do not, and `pip install` then tries to build
  from source and usually fails.
- The user reaches the Pi over SSH (`ssh user@<host>.local`) or the Raspberry
  Pi Connect remote shell. Connect gives a shell / screen, not the app's web
  port; for that see *Remote access* below.
- The repo is public, so `git clone` needs no credentials, and `git pull`
  is the update path.

## The pattern

1. **Install script in the app folder**, run as the normal user (refuse root),
   using `sudo` only for system steps. Make it **rerunnable**: the same command
   installs and updates.
2. **System packages**: check with `dpkg -s python3-venv`. On Debian,
   `python3 -m venv --help` succeeds even when the package is missing; only
   creating the venv fails (no `ensurepip`).
3. **Virtualenv inside the app folder** (`.venv`). Raspberry Pi OS marks the
   system Python as externally managed (PEP 668), so never `pip install`
   globally. Reinstall requirements only when `requirements.txt` changed
   (`cmp -s requirements.txt .venv/installed-requirements.txt`), the same
   convention the apps' `start.sh` / `start.bat` use.
4. **Offline self-test** (`python -m unittest`) before (re)starting, as a
   warning, not a blocker.
5. **systemd unit** written with `sudo tee /etc/systemd/system/<app>.service`:
   ```ini
   [Unit]
   After=network-online.target
   Wants=network-online.target

   [Service]
   User=<the user who ran the script>
   WorkingDirectory=<app folder>
   ExecStart=<app folder>/.venv/bin/python server.py --lan --no-browser
   Environment=PYTHONUNBUFFERED=1
   Restart=on-failure
   RestartSec=5

   [Install]
   WantedBy=multi-user.target
   ```
   then `daemon-reload`, `enable`, `restart`, and check `is-active`.
   A system unit (not a user unit) runs without anyone logged in, so it needs
   no `loginctl enable-linger`. The app must not need a desktop session:
   no clipboard, no browser opening (`--no-browser`), and it must listen on
   all interfaces (`--lan`) to be reachable from other devices.
6. **Print the URLs** at the end: `http://$(hostname).local:<port>` and the
   first address of `hostname -I` (some Android phones do not resolve
   `.local`).

## Operating it

`systemctl status <app>`, `sudo systemctl restart <app>`,
`journalctl -u <app> -f`; Cockpit (`:9090`, if installed) shows the same.
Git-ignored runtime files (settings, exports, debug output) stay in the app
folder and survive `git pull`.

## Remote access

Raspberry Pi Connect: device admin only (remote shell, screen sharing on the
desktop image). For the app itself use Tailscale on the Pi
(`curl -fsSL https://tailscale.com/install.sh | sh`, `sudo tailscale up`) or
Cloudflare Tunnel + Access. Apps here have no login of their own; never expose
one to the internet without an access layer in front.

## Testing the script without a Pi

The cloud sandbox has no systemd and runs as root. Put stubs first in `PATH`
for `id` (`-u` → 1000), `sudo` (redirect `tee` into a temp folder), `systemctl`
and `dpkg`, run the script against a `git archive` copy of the app, and check
the generated unit. Check `aarch64` wheels with
`pip download --only-binary=:all: --platform manylinux2014_aarch64 --python-version 311 <pkg>`.
