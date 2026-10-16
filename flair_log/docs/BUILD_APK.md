# Building the Android APK on GitHub

The Claude Code cloud sandbox cannot download the Android SDK (its network
policy blocks `dl.google.com`), so the APK is not built there. Instead the code
is pushed to GitHub and **GitHub Actions** builds it. The same approach was
used earlier for HomeGuard (`.github/workflows/homeguard-test-apk.yml`).

## How it works

1. The Flutter project lives in `flair_log/` in the repository
   `Cogur/sts-first-maven`, on a `claude/...` branch.
2. The workflow `.github/workflows/flair-log-test-apk.yml` runs on every push
   that changes `flair_log/**` (and can also be started by hand from the
   Actions tab with **Run workflow**).
3. The workflow runs on `ubuntu-latest`:
   - Java 17 (`actions/setup-java`)
   - Flutter 3.47.7 stable (`subosito/flutter-action`)
   - `flutter pub get`, `flutter analyze`, `flutter test`: the build stops
     if analysis or any test fails
   - `flutter build apk --release --build-number=<1000 + run number>`
4. The APK is published in two places:
   - **Releases page** as a pre-release named `Flair Log build N` (tag
     `flair-log-N`). This is the easiest download on a phone: open
     <https://github.com/Cogur/sts-first-maven/releases>, find the newest
     *Flair Log build*, tap the `.apk`.
   - **Artifacts** of the workflow run (zipped, kept 14 days, requires
     signing in to GitHub).

## Installing on the phone

1. Download `flair-log-N.apk` from the Releases page.
2. Open it. Android asks to allow installing from your browser or file
   manager the first time; allow it.
3. Start **Flair Log** and grant camera and Bluetooth ("Nearby devices")
   permission when asked.

## Signing

The release build is signed with the Android **debug key** (the default in
`android/app/build.gradle.kts`). That is fine for installing on your own
phone. It cannot go to Google Play.

The workflow caches `~/.android/debug.keystore` (`actions/cache`, key
`flair-log-debug-keystore-v1`), so consecutive builds use the same key and a
new APK installs **over** the old one, keeping your shots and calibration.
GitHub drops a cache that has not been used for 7 days. If that happens, the
next build has a new key and Android refuses the update ("App not installed").
Uninstall the old version first. Your saved shots are lost when you
uninstall, so export the ones you want to keep beforehand.

For a permanent key: create a keystore, store it base64-encoded as a
repository secret, and wire it into `signingConfigs`. The HomeGuard release
workflow (`homeguard-android-release.yml`) shows how.

## Doing it again (for Claude or by hand)

```bash
# in a clone of Cogur/sts-first-maven, on the app branch
git add flair_log .github/workflows/flair-log-test-apk.yml
git commit -m "..."
git push -u origin <branch>
# then watch the build
gh run list --workflow flair-log-test-apk.yml --limit 3
gh run watch <run-id>
gh release list --limit 5        # flair-log-N appears when the run finishes
```

## Building locally instead

You need the Flutter SDK and Android Studio (or the Android command-line
tools):

```bash
cd flair_log
flutter pub get
flutter build apk --release      # build/app/outputs/flutter-apk/app-release.apk
# or straight onto a phone connected via USB:
flutter run --release
```

iOS needs a Mac with Xcode: `flutter build ios` / open
`ios/Runner.xcworkspace`, set your signing team, then run on the device.

## When the build fails

- `flutter analyze` / `flutter test` failures show in the run like any step.
- If `flutter build apk` fails, the step **Report build error** copies the
  Gradle error into a run annotation and the job summary. From the Claude
  sandbox the raw log download is blocked, but annotations are readable:

  ```bash
  gh run view <run-id> --repo Cogur/sts-first-maven       # shows ANNOTATIONS
  ```
- Known pitfall: old plugin versions with outdated Gradle files. Keep
  `flutter_blue_plus` on 2.x. It needs `wakelock_plus` 1.8.0, because 1.8.1
  pulls a newer `dbus` that conflicts with it.
