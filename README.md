# Mix2Go — App (receiver)

Mix2Go streams a DAW's master audio over the local network to a phone, in real
time, so you can monitor your mix on a phone with no cable. **This repo is the
app** (the *receiver*). The sender is the companion
[Mix2Go plugin](https://github.com/eenness/Mix2Go) (C++/JUCE) that runs in the DAW.

```
DAW master ─▶ Mix2Go plugin ─(resample → Opus → UDP)─▶ Mix2Go app ─▶ speaker
```

## What it does
- Receives Opus-encoded audio over UDP from the plugin, **decodes** it, and
  plays it through the phone's audio output in real time.
- **Auto-discovery:** broadcasts a heartbeat so the plugin finds it — no setup.
  Includes a workaround for streaming over an iPhone Personal Hotspot.
- An adaptive **jitter buffer** absorbs network jitter, conceals packet loss
  (Opus FEC), and corrects clock drift between the two devices.
- Live UI: connection state, a stereo **dB VU meter**, and diagnostics
  (latency, packet loss, bitrate, underruns).

## Tech
- **Flutter / Dart**. Platforms: **iOS, Android, macOS, Windows**.
- Audio: `flutter_pcm_sound` (iOS/Android/macOS) + a custom WinMM backend on
  Windows; Opus via `opus_flutter` / `opus_dart`; networking via `udp` /
  `RawDatagramSocket`.

## Build & run
```bash
flutter pub get
flutter run -d <device>          # e.g. an iPhone, Android phone, or macos
flutter build ios --release      # release build
```
Android note: the native Opus plugin needs **NDK 27** and **minSdk 21** (already
configured). The app icon is generated with `flutter_launcher_icons`.

## Use
1. Load the **Mix2Go plugin** on your DAW's master bus.
2. Open this app on a phone on the same Wi-Fi (or the phone's hotspot).
3. Tap **Start receiving** — it connects automatically and shows the live meter.

## Layout
```
lib/
  main.dart                 libopus init + app root
  audio/
    audio_manager.dart      orchestrator: feed loop, drift correction, VU
    audio_buffer.dart       ReorderBuffer — the jitter buffer (seq order, FEC)
    windows_audio_output.dart  WinMM waveOut backend
  network/
    udp_receiver.dart       receive + parse v2 packet + Opus decode
    discovery_announcer.dart  heartbeat broadcast + hotspot unicast
  ui/
    theme.dart              design tokens
    home_page.dart          the screen
    widgets/                logo painter, status orb, VU meter, toggles
assets/
  branding/                 logo SVGs (design source)
  fonts/                    Barlow Condensed
```

## Architecture & protocol
See **[ARCHITECTURE.md](ARCHITECTURE.md)** for the full technical reference:
the discovery + audio wire protocols, the single-event-loop threading model and
why it bounds latency, the adaptive jitter buffer, and known limitations.
