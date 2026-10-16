# HomeGuard device simulator

Test the app on your phone without the real NVR, door station or indoor monitor. One PC runs fake versions of all of them:

| Fake device | Address on your PC | What it does |
|---|---|---|
| NVR, cameras 1–3 | `rtsp://<PC-IP>:8554/cam1_main` … `cam3_sub` | Moving test pattern; H.264 with G.711 audio on main streams, video only on sub streams. **Digest login**: `admin` / `admin123` |
| Door station video | `rtsp://<PC-IP>:8554/door_main`, `door_sub` | Same, for the door camera |
| Door relay | `http://<PC-IP>:8080/cgi-bin/accessControl.cgi?action=openDoor&channel=1` | Prints **DOOR UNLOCKED** in the terminal |
| Indoor monitor SD card | `http://<PC-IP>:8081/sdcard/snapshot/` | 4 sample events (face, call, motion, RFID card). A new one is added every 2 minutes |

## 1. Start it

**With Docker** (Windows, macOS or Linux):
```bash
cd homeguard/tools/simulator
docker compose up
```

**Without Docker** (Linux/macOS with `ffmpeg` and Python 3 installed):
1. Download `mediamtx` v1.9.3 from <https://github.com/bluenviron/mediamtx/releases/tag/v1.9.3>.
2. Run, in two terminals:
   ```bash
   ./mediamtx mediamtx.yml
   python3 fake_devices.py
   ```

Find your PC's LAN IP (`ipconfig` on Windows, `ipconfig getifaddr en0` on macOS, `hostname -I` on Linux). The phone must be on the **same Wi-Fi**. If the phone can't connect, allow ports 8554, 8080 and 8081 through the PC firewall.

## 2. Log in with the app

| Field | Value |
|---|---|
| NVR local IP | `<PC-IP>:8554` |
| Username / password | `admin` / `admin123` |
| Advanced → Camera RTSP path template | `/cam{channel}_{stream}` |

Try a wrong password first: you should see *Invalid username or password*. After 5 tries the login locks for 30 s.

## 3. Configure the door station and monitor (Settings → Devices)

**Front Door**
- LAN IP: `<PC-IP>`
- RTSP port: `8554`
- HTTP port: `8080`
- RTSP path template: `/door_{stream}`
- Unlock endpoint: `/cgi-bin/accessControl.cgi?action=openDoor&channel=1` (method GET)
- Turn **Two-way audio** off: the simulator has no ONVIF back-channel.

**Indoor Monitor**
- LAN IP: `<PC-IP>`
- HTTP port: `8081`
- SD-card index path: `/sdcard/snapshot/`

## 4. Test checklist

- [ ] **Live** tab shows 4 moving test patterns, each with a green **LAN** badge.
- [ ] Tap a tile. Fullscreen opens; HD/SD switches stream; pinch-zoom works; you hear a 440 Hz tone on main streams (unmute).
- [ ] **Snapshot** in fullscreen saves an image to the **Events** tab.
- [ ] **Access** tab: *Hold to unlock* → biometric prompt → the PC terminal prints *DOOR UNLOCKED* → entry appears in the access log.
- [ ] **Events → Sync**: imports the face, call, motion and card events with correct tags and times. Wait 2 minutes, sync again, and only the new event arrives.
- [ ] **Settings → Network status → Probe stream** (on the Front Door): shows H264, PCMU and *back-channel: no*.
- [ ] Stop the simulator (Ctrl-C). Tiles show an error and retry, with no crash. Start it again and the streams come back by themselves.
- [ ] Switch the phone to mobile data: the devices turn **Unreachable**, because there is no remote route.
- [ ] Put the app in the background for longer than the auto-lock time. Coming back requires biometrics.

**Not covered by the simulator:**
- two-way talk (needs a real door station with ONVIF back-channel);
- the real Techson URL formats;
- RFID access events coming from the door station itself.

## Android emulator instead of a phone
In the Android emulator, the PC is reachable at `10.0.2.2`, so log in with `10.0.2.2:8554`.

## Automated check
With the simulator running:
```bash
HOMEGUARD_SIM_HOST=127.0.0.1 flutter test test/simulator_test.dart
```
