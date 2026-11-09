# Scrobbler

A personal iPhone app that identifies music in device audio and sends qualifying plays to Last.fm. The app keeps captured PCM in memory and sends an audio fingerprint to the unofficial Shazam lookup endpoint. Last.fm receives track and listening metadata.

## Build and install

The **Build iPhone IPA** GitHub Actions workflow uses the Apple Silicon `xcode-27` image. A push to `main` starts the build, and the workflow can also be run manually from the Actions tab. Download the `Scrobbler-unsigned` artifact after a successful run, extract the IPA, and try signing and installing it with AltStore Classic and AltServer. The app requires iOS 27. A free Apple Account requires refreshing the installation every seven days. [GitHub’s runner image](https://github.blog/changelog/2026-10-15-xcode-27-runner-image-generally-available/) · [AltStore on macOS](https://faq.altstore.io/altstore-classic/how-to-install-altstore-macos)

For a local build on a Mac with Xcode 27, install Rust and XcodeGen, then run:

```sh
bash scripts/build-fingerprint.sh
xcodegen generate
open Scrobbler.xcodeproj
```

Apple’s iOS ScreenCaptureKit sample requests the Screen Recording entitlement, and this Xcode project requests it too. The signing profile must authorize it. The unsigned IPA is useful for checking installation and the WAV recognition path. Full-display capture requires checking what the final signature and provisioning profile grant, including when using a free Personal Team or AltStore. Record the exact on-screen error if the picker or stream fails. [Apple’s iOS ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-on-ios)

## First device test

- Launch the app, tap **Start listening**, and select full-display capture in the system picker. Play music in the regular YouTube or SoundCloud app through AirPods. Confirm that the audio meter and window count move, then check whether a song is recognized.
- With playback continuing, test switching apps, pausing, and locking the phone. A successful install establishes signing. The meter and recognition results establish capture behavior for that app and route.
- To isolate recognition from capture, tap **Test a WAV file** and choose a mono 16 kHz WAV at least 12 seconds long. The test updates the match display without recording a listen. For the known test clip, convert “Sneaky Snitch” by Kevin MacLeod starting at 00:30 with the command below. The source is licensed under CC BY 3.0. [Artist download and license](https://www.incompetech.com/music/royalty-free/index.html?isrc=USUAN1100772)

```sh
ffmpeg -ss 30 -i 'Sneaky Snitch.mp3' -t 12 -ac 1 -ar 16000 -c:a pcm_s16le scrobbler-test.wav
```

## Last.fm setup

Create a Last.fm API account and enter its key and shared secret in the app’s settings. Tap **Authorize in browser**, grant access, then return to the app and tap **Finish authorization**. The app keeps credentials in Keychain and persists eligible plays in its local retry queue. [Create a Last.fm API account](https://www.last.fm/api/account/create)

Two consecutive matches confirm a play. Tracks longer than 30 seconds qualify after half their duration or four minutes of matched audio, whichever comes first. Unknown lengths remain visible in local history. Stop capture before using Spotify if Spotify already scrobbles independently. [Last.fm scrobble rules](https://www.last.fm/api/scrobbling)

## Checks

Run `cargo test --locked --manifest-path Fingerprint/Cargo.toml` for native fingerprint checks. The workflow also compiles and runs `Tests/PlayTrackerChecks.swift` to check repeat windows, qualification, track changes, and gaps. See [Fingerprint/UPSTREAM.md](Fingerprint/UPSTREAM.md) for the pinned fingerprint implementation and license details.
