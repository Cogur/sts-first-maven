# HomeGuard Bridge

SuperLive Plus reaches a recorder anywhere by its **cloud serial number**: TVT's P2P servers connect phone
and recorder, so nobody configures a router. TVT ships that P2P client only inside its **Linux/Windows
NET_SDK** (no Android/iOS build, no protocol documentation), so the phone app cannot do this by itself yet.

The bridge runs that SDK on an always-on x86_64 Linux machine and re-publishes the recorder to HomeGuard:

```
 phone (HomeGuard) ──TLS──►  HomeGuard Bridge  ──TVT P2P (UDP, by serial)──►  NVR at home
   rtsps://bridge:8322         vendor NET_SDK                                 (no port forwarding)
   https://bridge:8443         + mediamtx/ffmpeg
```

* **Live video**: `rtsps://<bridge>:8322/<device>_ch<N>_<main|sub>`
* **Playback**: `rtsps://<bridge>:8322/<device>_ch<N>_pb_<YYYYMMDDhhmmss>_<YYYYMMDDhhmmss>`
* **HTTPS API** (Basic auth):
  * `GET /api/devices`
  * `GET /api/devices/<id>/channels/<N>/snapshot.jpg`
  * `GET /api/devices/<id>/channels/<N>/recordings?from=…&to=…`
  * `POST /api/devices/<id>/alarm-outputs/<n>/pulse?ms=1000` (door relay, experimental)

Video is only re-muxed (`-c copy`), never re-encoded, so a small VPS is enough.

## Status and legal

* Built on public reverse-engineering: [2BAD/tvt](https://github.com/2BAD/tvt) (MIT, which also
  redistributes the vendor libraries) and the serial-login fix documented by
  [Argus-Community](https://github.com/AlphaTechCodeworks/Argus-Community). `native/hg_p2p_serial.c` is an
  independent implementation of that fix: the SDK sends `MD5(serial)` to the P2P servers, which only know the
  plain serial.
* The vendor libraries are **not** in this repository. `scripts/fetch-sdk.sh` downloads them at build time.
* It uses TVT's cloud servers and SDK **without TVT's permission**. That is reasonable for your own
  devices, but not for a public service, which needs TVT's written consent.
* Not yet tested against the Techson TCR I12. The unit tests run against a fake SDK (`npm test`).

## Run it

Requirements: Docker on **x86_64 Linux** (TVT ships no ARM build, so a Raspberry Pi will not work), plus a
**domain name with a real TLS certificate**. The phone rejects self-signed certificates on purpose.

1. Copy the configuration templates:
   ```bash
   cd homeguard/tools/bridge
   cp config/bridge.example.json config/bridge.json
   cp .env.example .env
   ```
2. In `config/bridge.json`, set the recorder's cloud serial. You can read it in:
   - SuperLive Plus → device → *Device info*;
   - the NVR's *Function Panel → Network → NAT* page;
   - HomeGuard → Settings → *Device diagnostics*, which shows it masked.
3. In `.env`, set a long `BRIDGE_PASSWORD` and the NVR password (`NVR_PASSWORD`).
4. Put your certificate in `certs/bridge.crt` and `certs/bridge.key`, for example from Let's Encrypt.
5. Start the bridge:
   ```bash
   docker compose up -d --build
   docker compose logs -f bridge     # "[nvr] online: …" after 5-20 s
   ```
6. In the app, sign in:
   - **Remote access → Bridge**, with the bridge's domain;
   - username and password: `BRIDGE_USER` / `BRIDGE_PASSWORD`.

   **Tip:** use the NVR's own account as `BRIDGE_USER` / `BRIDGE_PASSWORD`. Then you can also fill in the
   NVR's local IP: at home the app goes straight to the NVR over the LAN, and away it uses the bridge,
   with one sign-in.

The playback times follow the bridge's `TZ`. Set it to the recorder's time zone.

### P2P servers

The default is `cli-nat20.eyeincloud.com:9969`, the server SuperLive uses. Other P2P 2.0 servers seen in the
field:
- `device.provisionisr-nat2.com:9968`
- `c2020.autonat.com:7968`

Set `natServer` in `bridge.json`. The SDK accepts it once per process.

## Development

```bash
npm test          # API + feed tests on a fake SDK, and the C shim against a fake NAT library
npm run fetch-sdk # vendor libraries into vendor/ (x86_64 Linux)
```
