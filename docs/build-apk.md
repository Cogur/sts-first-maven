# Building an installable Android APK (any Flutter app in this repo)

Applies to **every** Flutter app here, including new ones: set this up as part
of creating the app, without being asked. Used by HomeGuard
(`homeguard-test-apk.yml`) and Flair Log (`flair-log-test-apk.yml`), each on
its app branch (see the app table in `AGENTS.md`).

## Why GitHub Actions

The Claude Code cloud sandbox cannot build APKs: its network policy blocks
`dl.google.com`, so the Android SDK and Google's Maven repository are
unreachable. Code is pushed to GitHub and a workflow builds the APK there.
Flutter itself, `pub get`, `flutter analyze` and `flutter test` do work in
the sandbox; run them before pushing.

## Setting it up for a new app

1. The app lives in its own folder, e.g. `<app>/` (Flutter project root).
2. Copy the template below to `.github/workflows/<app>-test-apk.yml`. Replace
   `<app>` with the folder name and `<App Name>` with the display name.
3. Keep `flutter-version` the same as the Flutter version the app was
   created and tested with.
4. Add `<app>/docs/` notes only for what is specific to the app (signing for
   the store, extra build flags). Link back here instead of copying this file.
5. Push, then check the run (see *Checking a build* below). Give the user the
   direct `.apk` link from the release.

## What the workflow does

- Runs on every push that touches `<app>/**`, on PRs, and by hand
  (Actions tab → *Run workflow*).
- Java 17, Flutter stable at a pinned version, then
  `flutter pub get` → `flutter analyze` → `flutter test` → `flutter build apk --release`.
  A failing analyze or test stops the build.
- Build number = `1000 + run number`, so every build is newer than the last.
- Publishes the APK twice:
  - **Releases page** as a pre-release `<App Name> build N` (tag
    `<app>-N`). This is the phone-friendly link: no zip, no sign-in for a
    public repo.
  - **Artifacts** of the run (zipped, 14 days).
- If the Gradle build fails, a step copies the error into a run
  **annotation** and the job summary (raw logs cannot be downloaded from the
  sandbox; annotations can).

## Signing

Test APKs are signed with the Android **debug key**. That is fine for
sideloading, and Google Play does not accept it. The workflow caches
`~/.android/debug.keystore` (`actions/cache`), so consecutive builds share a key
and a new APK installs over the old one, keeping app data. A cache unused for
7 days is dropped. The next build then gets a new key, and Android refuses the
update until the old app is uninstalled, which deletes its data. Tell the user
this.

For store releases use a real upload key from repository secrets. See
`homeguard/docs/PLAY_STORE.md` and `homeguard-android-release.yml` on the
HomeGuard branch.

## Template: `.github/workflows/<app>-test-apk.yml`

```yaml
name: <App Name> test APK

on:
  push:
    paths:
      - '<app>/**'
      - '.github/workflows/<app>-test-apk.yml'
  pull_request:
    paths:
      - '<app>/**'
  workflow_dispatch:

permissions:
  contents: write   # publish the APK as a pre-release on the Releases page

concurrency:
  group: <app>-test-apk-${{ github.ref }}
  cancel-in-progress: true

jobs:
  apk:
    runs-on: ubuntu-latest
    timeout-minutes: 45
    defaults:
      run:
        working-directory: <app>
    steps:
      - uses: actions/checkout@v4

      - uses: actions/setup-java@v4
        with:
          distribution: temurin
          java-version: '17'

      - uses: subosito/flutter-action@v2
        with:
          channel: stable
          flutter-version: 3.47.7
          cache: true

      # Same debug key between runs, so updates install over the old app.
      - name: Restore debug signing key
        uses: actions/cache@v4
        with:
          path: ~/.android/debug.keystore
          key: <app>-debug-keystore-v1

      - run: flutter pub get
      - run: flutter analyze
      - run: flutter test

      - name: Build APK
        run: |
          set -o pipefail
          flutter build apk --release --build-number=$((1000 + GITHUB_RUN_NUMBER)) \
            2>&1 | tee "$RUNNER_TEMP/build.log"
          mv build/app/outputs/flutter-apk/app-release.apk \
             "build/app/outputs/flutter-apk/<app>-${GITHUB_RUN_NUMBER}.apk"

      - name: Report build error
        if: failure()
        run: |
          [ -f "$RUNNER_TEMP/build.log" ] || exit 0
          msg=$(grep -E -A12 "What went wrong|error:|Error:|FAILURE" "$RUNNER_TEMP/build.log" \
                | head -60 | sed 's/%/%25/g' | awk '{printf "%s%%0A", $0}')
          echo "::error title=flutter build apk failed::${msg}"
          { echo '```'; tail -80 "$RUNNER_TEMP/build.log"; echo '```'; } >> "$GITHUB_STEP_SUMMARY"

      - uses: actions/upload-artifact@v4
        with:
          name: <app>-apk-${{ github.run_number }}
          path: <app>/build/app/outputs/flutter-apk/<app>-*.apk
          retention-days: 14

      - name: Publish APK on the Releases page
        if: github.event_name != 'pull_request'
        uses: softprops/action-gh-release@v2
        with:
          tag_name: <app>-${{ github.run_number }}
          name: <App Name> build ${{ github.run_number }}
          target_commitish: ${{ github.sha }}
          prerelease: true
          make_latest: false
          files: <app>/build/app/outputs/flutter-apk/<app>-*.apk
          body: |
            Test build of <App Name> from `${{ github.ref_name }}` @ ${{ github.sha }}.
            Open this page on your Android phone, download the .apk and open it.
            Debug-signed: for testing only.
```

## Checking a build (from the sandbox)

GraphQL-based `gh` commands (`gh release view`, `gh pr …`) are blocked; use
`gh run` and `gh api` (REST).

```bash
gh run list  --repo Cogur/sts-first-maven --workflow <app>-test-apk.yml --limit 3
gh run view  <run-id> --repo Cogur/sts-first-maven      # status + ANNOTATIONS (build errors)
gh api repos/Cogur/sts-first-maven/releases/tags/<app>-<N> \
  --jq '.assets[].browser_download_url'                  # direct .apk link
```

A new push to the same branch cancels a running build (`concurrency`). Wait
for a build to finish before pushing again if you want its APK.

## Known pitfalls

- **Plugin with an outdated Android Gradle file breaks `flutter build apk`**
  even though analyze and test pass. Check `flutter pub outdated` for plugins
  held back to an old major version, and find out what holds them back
  (`flutter pub add <pkg>:^<latest>` prints the conflict). Example from Flair
  Log: `wakelock_plus` 1.8.1 needs `dbus` 0.8, which forced `flutter_blue_plus`
  down to 1.34.5. Pinning `wakelock_plus` 1.8.0 allowed `flutter_blue_plus`
  2.x, and the build passed.
- **`flutter_blue_plus` 2.x** requires `connect(license: ...)`.
  `License.nonprofit` covers personal use. Commercial use needs a paid
  license, so tell the user.
- Shallow clones in the sandbox may not track a pushed branch, and the stop
  hook then reports "unpushed commits". Fix:
  `git config --add remote.origin.fetch '+refs/heads/<branch>:refs/remotes/origin/<branch>' && git fetch origin <branch> && git branch -u origin/<branch>`.

## Installing on the phone

Open the release page on the phone, tap the `.apk`, allow installs from the
browser when Android asks, open it.

## Building locally instead

Needs Flutter and the Android SDK (Android Studio): `cd <app> && flutter build apk --release`,
or `flutter run --release` with the phone on USB. iOS builds need a Mac with Xcode.
