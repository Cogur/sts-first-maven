# Publishing HomeGuard to Google Play

The repository contains everything needed to produce and upload a signed release:
- `android/app/build.gradle.kts`: release signing. It never falls back to the debug key.
- `.github/workflows/homeguard-android-release.yml`: runs analyze and tests, builds a signed `.aab`, then uploads it to a Play track as a **draft**.

The steps below need **your** Google account, your signing key and your decisions, so they can't be automated from this repo.

---

## 0. Decide before the first upload (these are permanent)

- [ ] **Application ID.** It is currently `com.homeguard.local.homeguard` and can never change after the first upload. Pick your own (e.g. `com.yourname.homeguard`). Then update:
  - `applicationId` in `android/app/build.gradle.kts`
  - `PACKAGE_NAME` in the workflow
- [ ] **App name.** Search Play for "HomeGuard" first; the name may already be taken. Don't use "Techson", "TVT" or "SuperLive" in the title or icon: they are third-party trademarks. In the description, say "compatible with Techson/TVT devices".
- [ ] **Launcher icon.** The project still ships the default Flutter icon. Replace it, for example with `flutter_launcher_icons` and a 1024×1024 PNG.

## 1. Google Play Console account

1. Register at <https://play.google.com/console/signup>. There is a one-time $25 fee and identity verification.
2. **New personal accounts** must run a **closed test with at least 12 testers for 14 consecutive days** before they can publish to production. Organisation accounts are exempt. Plan for this.

## 2. Create the upload key (on your machine, once)

```bash
keytool -genkey -v -keystore ~/homeguard-upload.jks -keyalg RSA -keysize 4096 \
        -validity 10000 -alias upload
```

Back up the `.jks` file and its passwords somewhere safe. With Play App Signing (the default), Google holds the real app-signing key, and a lost upload key can be reset through support.

For local builds, create `homeguard/android/key.properties`. It is git-ignored; never commit it.

```properties
storeFile=/absolute/path/homeguard-upload.jks
storePassword=...
keyAlias=upload
keyPassword=...
```

Then build:

```bash
flutter build appbundle --release   # → build/app/outputs/bundle/release/app-release.aab
```

## 3. Create the app in Play Console and do the first upload by hand

The Play API cannot create an app or accept its very first bundle.

1. **Create app**: choose the name, default language, *App*, *Free*, and accept the declarations.
2. Go to **Testing → Internal testing → Create release**. Accept **Play App Signing**, then upload `app-release.aab`.
3. Complete **App content**:

   | Section | Answer |
   |---|---|
   | Privacy policy | Public URL of `docs/PRIVACY_POLICY.md`. Host it with GitHub Pages or any website; a private-repo link won't work. Fill in your contact email first. |
   | Ads | No |
   | App access | "All functionality requires the user's own NVR on their network". Give reviewers instructions, or a demo RTSP device if you can, otherwise review may reject for "can't access app". |
   | Content rating | Utility. No violence, UGC or gambling. |
   | Target audience | 18+ |
   | Data safety | **No data collected, no data shared.** Data is encrypted at rest; users can request deletion (*Erase all data* in the app). |
   | Government / financial / health apps | No |

4. Write the **Store listing** (draft below) and upload:
   - at least 2 phone screenshots,
   - a 512×512 icon,
   - a 1024×500 feature graphic.

## 4. Automate later uploads (GitHub Actions)

1. In Google Cloud, create a service account and a JSON key.
2. In Play Console, go to **Users & permissions → Invite user**, add the service account email, and grant *Release to testing tracks* (plus *Release to production* if you want that) for this app.
3. In GitHub, open **Settings → Secrets and variables → Actions** and add:

   | Secret | Value |
   |---|---|
   | `ANDROID_KEYSTORE_BASE64` | `base64 -w0 homeguard-upload.jks` |
   | `ANDROID_KEYSTORE_PASSWORD` | keystore password |
   | `ANDROID_KEY_ALIAS` | `upload` |
   | `ANDROID_KEY_PASSWORD` | key password |
   | `PLAY_SERVICE_ACCOUNT_JSON` | contents of the service-account JSON |

4. Go to **Actions → HomeGuard Android release → Run workflow** and pick a track.
   - The release is created as a **draft**. Review it and click *Roll out* in Play Console.
   - The version code is `1000 + run number`, so it always increases.

## 5. Before going to production

- [ ] Test on real hardware: NVR, door station and indoor monitor (see README "Known limitations").
- [ ] Run the closed test (12 testers / 14 days) if your account requires it.
- [ ] Go through the pre-launch report in Play Console (crashes on Google's test devices).

---

## Store listing draft

**Short description (80 chars max)**
> Private, local-first viewer for your NVR, IP cameras and video intercom.

**Full description**
> HomeGuard connects directly to your own NVR, IP cameras and IP video intercom. There is no cloud, no account and no tracking.
>
> • Live view of all cameras and the door station in one grid; fullscreen with pinch-zoom
> • Two-way talk with the door station (ONVIF audio back-channel)
> • Door unlock, protected by biometric confirmation and hold-to-unlock
> • Event timeline: face detection, doorbell calls, motion and snapshots, stored only on your phone
> • Local network first for the lowest latency; optional remote access only through your VPN or TLS
> • Credentials encrypted in the Android Keystore; fingerprint / face unlock
> • ONVIF discovery and RTSP diagnostics
>
> Compatible with RTSP/ONVIF devices, including Techson/TVT-family recorders. HomeGuard is an independent app and is not affiliated with Techson or TVT.
