# Flair Log APK

The build process is shared by all apps: see [`../../docs/build-apk.md`](../../docs/build-apk.md).
This file only records what is specific to Flair Log.

- Workflow: `.github/workflows/flair-log-test-apk.yml`. It runs on pushes touching `flair_log/**`.
- Downloads: Releases page, `Flair Log build N` (tag `flair-log-N`), file `flair-log-N.apk`.
- Signing: debug key cached under `flair-log-debug-keystore-v1`. Uninstalling to switch keys
  deletes saved shots, so export the ones you want first (shot screen → share).
- App id `com.flairlog.flair_log`. Permissions: camera, Bluetooth "Nearby devices".
- iOS: needs a Mac with Xcode (`ios/Runner.xcworkspace`).
