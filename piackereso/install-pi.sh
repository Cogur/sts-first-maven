#!/usr/bin/env bash
# Piackereső telepítése Raspberry Pi-re (Raspberry Pi OS, 64 bit) rendszerszolgáltatásként:
# a Pi bekapcsolásakor magától elindul, és ha leállna, újraindul.
#
#   ./install-pi.sh                 # telepítés, vagy frissítés után újrafuttatva: újraindítás
#   PORT=8080 ./install-pi.sh       # másik port
#
# A saját felhasználóddal futtasd (ne sudo-val); ahol kell, a szkript maga kér sudo-t.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")" && pwd)"
APP_USER="$(id -un)"
PORT="${PORT:-8765}"
SERVICE=piackereso

if [ "$(id -u)" -eq 0 ]; then
  echo "Ne sudo-val / rootként futtasd, hanem a saját felhasználóddal: ./install-pi.sh" >&2
  exit 1
fi
if [ "$(uname -m)" != "aarch64" ]; then
  echo "Figyelem: nem 64 bites rendszer ($(uname -m)). A curl_cffi csomag itt valószínűleg nem települ;" >&2
  echo "a 64 bites Raspberry Pi OS ajánlott." >&2
fi

echo "== Rendszercsomagok (python3-venv)"
if ! dpkg -s python3-venv >/dev/null 2>&1; then
  sudo apt-get update
  sudo apt-get install -y python3-venv python3-pip
else
  echo "   már telepítve"
fi

echo "== Python-csomagok (.venv)"
cd "$APP_DIR"
[ -d .venv ] || python3 -m venv .venv
if ! cmp -s requirements.txt .venv/installed-requirements.txt; then
  .venv/bin/pip install --upgrade pip
  .venv/bin/pip install -r requirements.txt
  cp requirements.txt .venv/installed-requirements.txt
else
  echo "   már telepítve"
fi

echo "== Önellenőrzés (tesztek)"
if .venv/bin/python -m unittest discover -s tests -q >/tmp/piackereso-tests.log 2>&1; then
  echo "   rendben"
else
  echo "   FIGYELEM: néhány teszt nem ment át, részletek: /tmp/piackereso-tests.log" >&2
fi

echo "== Szolgáltatás: /etc/systemd/system/$SERVICE.service"
sudo tee "/etc/systemd/system/$SERVICE.service" >/dev/null <<EOF
[Unit]
Description=Piackereső (használtpiac-kereső)
After=network-online.target
Wants=network-online.target

[Service]
User=$APP_USER
WorkingDirectory=$APP_DIR
ExecStart=$APP_DIR/.venv/bin/python server.py --lan --no-browser --port $PORT
Environment=PYTHONUNBUFFERED=1
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable "$SERVICE" >/dev/null
sudo systemctl restart "$SERVICE"
sleep 2

if systemctl is-active --quiet "$SERVICE"; then
  echo
  echo "Kész, a Piackereső fut. Nyisd meg a böngészőben:"
  echo "   http://$(hostname).local:$PORT"
  ip_addr="$(hostname -I 2>/dev/null | awk '{print $1}')"
  [ -n "$ip_addr" ] && echo "   http://$ip_addr:$PORT"
else
  echo "A szolgáltatás nem indult el. Napló: journalctl -u $SERVICE -n 50" >&2
  exit 1
fi
