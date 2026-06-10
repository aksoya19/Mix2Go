# Mix2Go — Architecture & Technical Reference

Mix2Go streams the master audio of a DAW (digital audio workstation) over the
local network, in real time, to a phone — so a music producer can monitor their
mix on headphones/earbuds connected to a phone without a cable. It is two
programs that talk to each other over UDP:

| Component | Tech | Role |
|---|---|---|
| **Mix2Go plugin** | C++ / JUCE (VST3 · AU · Standalone) | runs inside the DAW, **encodes + sends** the master audio |
| **Mix2Go app** | Flutter / Dart (iOS · Android · macOS · Windows) | **receives + decodes + plays** the audio |

The two find each other automatically (UDP discovery), so there's normally no
setup — open the app, the plugin connects, audio plays.

```
   ┌─────────────────────── Computer (DAW) ──────────────────────┐        ┌──────── Phone ────────┐
   │  master bus ─▶ Mix2Go plugin                                │        │  Mix2Go app           │
   │                 ├─ resample → Opus encode                   │  UDP   │   ├─ Opus decode       │
   │                 └─ packetize ───────────────────────────────┼──────▶ │   ├─ jitter buffer    │
   │                                                             │ audio  │   └─ speaker          │
   │  Mix2Go app ◀───────────────────────────────────────────────┼──────  │  broadcasts "I'm here"│
   │   (discovery: plugin listens)                               │ disc.  │                       │
   └─────────────────────────────────────────────────────────────┘        └───────────────────────┘
```

---

## 1. End-to-end data flow

The journey of one chunk of audio, DAW → phone speaker:

1. **DAW** calls the plugin's `processBlock()` on its real-time **audio thread**, handing it the master buffer (e.g. 512 float samples × 2 channels at the project sample rate).
2. The plugin applies a **transport fade** (so play/pause doesn't click) and pushes the samples into a **lock-free FIFO**.
3. A separate **network thread** pops one frame's worth out of the FIFO, **resamples** it to 48 kHz, **Opus-encodes** it (10 ms / 480-sample frames, 256 kbps), wraps it in a **28-byte header**, and sends it as one **UDP datagram**.
4. The datagram crosses the network (Wi-Fi / hotspot) to the phone.
5. The app's UDP socket receives it on the **Dart event loop**, parses the header, **Opus-decodes** the payload to PCM, and inserts it into a **jitter buffer** keyed by sequence number.
6. The OS audio engine periodically asks the app for more samples (a "feed" callback). The app pulls the next frame from the jitter buffer (in order), handling loss/drift, and hands it to the speaker.

Steps 1–3 happen ~100 times per second (one 10 ms frame each); step 6 likewise.

---

## 2. Wire protocols

### 2.1 Discovery (so they find each other)

- The **app broadcasts** a tiny ASCII heartbeat once per second on **UDP port 40051**:
  `MIX2GO:2:<audioPort>` — where `<audioPort>` is the OS-assigned port the app is listening on for audio.
- The **plugin listens** on 40051. When it receives a valid heartbeat it learns the app's **IP (from the datagram's source address)** and **port (from the payload)**, and starts streaming there. No manual IP entry.
- Heartbeat timeout: if the plugin hears nothing for 3 s it marks the device "lost" (but keeps the audio stream alive — see §6).

**Broadcast targets** (the app sends the heartbeat to several addresses to maximise reach):
- `255.255.255.255` (limited broadcast)
- `<subnet>.255` for every non-loopback interface (covers Wi-Fi, Ethernet, VPN/ZeroTier adapters)
- **Hotspot workaround:** when the phone *is* the hotspot access point it gets the fixed IP `172.20.10.1`, and iOS sends broadcasts out the *cellular* interface where the Mac can't see them. So the app additionally **unicasts** the heartbeat to every client address in the hotspot's tiny `/28` subnet (`172.20.10.2`–`172.20.10.14`). One of those is the Mac, and unicast *is* routed across the hotspot bridge. (Toggle: `_kEnableHotspotWorkaround`.)

### 2.2 Audio packet (v2 format)

Each datagram = a 28-byte little-endian header + the Opus payload:

| Offset | Size | Field | Notes |
|---|---|---|---|
| 0  | 4 | magic | `0x4D324731` = "M2G1" |
| 4  | 1 | frameType | 0 = Opus audio, 2 = EOS (end-of-stream) |
| 5  | 1 | numChannels | 2 |
| 6  | 2 | payloadLen | Opus payload byte count |
| 8  | 4 | sequenceNumber | increments by 1 per packet; used for ordering & loss detection |
| 12 | 8 | timestamp (µs) | informational |
| 20 | 4 | sampleRate | 48000 |
| 24 | 4 | frameSamples | 480 (10 ms @ 48 kHz) |
| 28 | … | Opus payload | |

The **sequence number** is the backbone of the receiver: gaps = packet loss
(→ concealment), and it's how the jitter buffer re-orders packets that arrive
out of order.

---

## 3. The plugin (sender) — C++ / JUCE

Source: `source/`. Key files under `source/Streaming/` and the editor.

### Threading model (4 threads)
| Thread | Owner | Does |
|---|---|---|
| **Audio** | the DAW | `processBlock()` — metering, transport fade, FIFO **push** |
| **Network** | `NetworkSender` | FIFO **pop** → resample → Opus encode → UDP send, on an absolute-time clock |
| **Discovery** | `DiscoveryReceiver` | listens for the app's heartbeat |
| **Message** | JUCE | the editor UI (paint + 30 Hz meter timer) |

The **FIFO is the bridge** between the audio thread (fast, must never block) and
the network thread (slower, does the heavy encoding).

### Components
- **`PluginProcessor`** — the plugin entry point. `processBlock()` measures peak levels (for the meters), applies a **transport-aware gain fade** (reads the DAW's play/stop state from the playhead; ramps audio in/out over ~8 ms so transport changes don't click), and pushes the buffer to the FIFO when streaming.
- **`ThreadSafeFIFO`** — a wrapper over `juce::AbstractFifo` (lock-free ring buffer), ~100 ms capacity. Decouples push rate (audio thread) from pop rate (network thread).
- **`MixOpusEncoder`** — resamples the DAW's rate → 48 kHz with a `juce::LagrangeInterpolator`, accumulates 480-sample (10 ms) frames, and Opus-encodes them. Config: **256 kbps, complexity 10, in-band FEC on, music-optimised**. FEC (forward error correction) embeds a low-bitrate copy of the *previous* frame in each packet, so the receiver can reconstruct a single lost frame.
- **`NetworkSender`** — its own thread running an **absolute-timing** loop (`nextSendTick += interval`), so send timing never drifts. Each tick it asks `AudioStreamManager` for the next packet and `write()`s it to the UDP socket. On transport pause the FIFO starves; the sender then emits **silence frames without counting them as underruns**, keeping the sequence numbers continuous so playback resumes seamlessly.
- **`DiscoveryReceiver`** — its own thread; binds 40051, parses heartbeats, reports the discovered IP/port to `AudioStreamManager` on the message thread.
- **`AudioStreamManager`** — the orchestrator. Wires the encoder, FIFO, sender and discovery together; owns the stream state machine (`Disconnected → Connecting → Streaming → Error`); builds the v2 packet (`buildV2Packet`); exposes stats (packets/bytes sent, FIFO level, underruns).
- **Editor (`PluginEditor` + `Mix2GoLookAndFeel`)** — the redesigned UI. Almost everything is hand-painted: the logo, the MIX2GO wordmark (embedded Barlow Condensed font), the big status word, the **dB stereo VU meters**, and the stats bar. The JUCE UI runs on the message thread (separate from audio), so it can animate at 30 fps with no audio impact.

---

## 4. The app (receiver) — Flutter / Dart

Source: `lib/`. **Everything runs on a single Dart isolate (the main event
loop)** — UDP receive, Opus decode, the jitter buffer, the audio feed callback,
*and* the UI. This single-threadedness is the source of most of the design
constraints (see §6, §7).

### Components
- **`main.dart`** — initialises libopus (`initOpus(await opus_flutter.load())`) before any decode, then runs the app.
- **`UdpReceiver`** — binds a UDP socket (OS-assigned port), `listen`s for datagrams, parses the v2 header, **Opus-decodes** the payload, and hands the PCM frame to the buffer. Owns the shared Opus decoder (needed for FEC, which depends on decoder history).
- **`ReorderBuffer`** (the jitter buffer) — a `SplayTreeMap<int, PCM>` keyed by sequence number. Accepts packets in any order, releases them **in sequence**. A missing sequence number = a gap → the caller requests **Opus FEC concealment**. `seekToLatest()` trims the buffer to the newest packets to control latency; it also **drops a far "straggler"** packet (one separated from the cluster by a gap bigger than the keep window) so the decoder doesn't FEC-walk a huge startup gap.
- **`AudioManager`** — the orchestrator and the heart of the receiver. Runs the **pull-model feed loop**: the OS audio engine (`flutter_pcm_sound`) calls back when it needs samples; `AudioManager` pulls frames from the jitter buffer, runs the **clock-drift state machine**, computes **VU levels**, and feeds the hardware. Also drives discovery and exposes all the stats the UI shows.
- **`DiscoveryAnnouncer`** — broadcasts the `MIX2GO:2:<port>` heartbeat (and the hotspot unicast scan) every second.
- **`WindowsAudioOutput`** — a custom WinMM `waveOut` backend for Windows (where `flutter_pcm_sound` isn't used).
- **UI (`lib/ui/`)** — `theme.dart` (design tokens), the painted logo (`Mix2GoIconPainter`), the status orb, the dB VU meter (`vu_meter.dart`), toggle panels, and `home_page.dart`. The VU meter is fed by a **throttled `ValueNotifier`** so the audio feed loop isn't starved by UI rebuilds (see §7).

### The audio feed loop (`AudioManager._onFeedNeeded`)
The OS engine pulls; the app never pushes on a timer (that avoids timer drift).
Each callback:
1. On the **first** callback, `seekToLatest(_kPreBuffer)` discards the startup backlog and snaps to real-time.
2. **Overflow trim:** if the buffer grew past `_kOverflowPackets` (clock drift, DAW faster), trim to `_kSteadyBuffer`.
3. Pull `kFramesPerFeed` (4 = 40 ms) frames from the buffer; missing ones → Opus FEC.
4. **Drift detection:** count consecutive all-empty callbacks; ≥ `_kDriftThreshold` → enter **rebuffering** (feed silence until the buffer refills, then resume) — this fixes the slow drain when the phone clock runs faster than the DAW.
5. Compute peak VU levels and feed the buffer to the hardware.

---

## 5. The receiver's adaptive jitter buffer (the clever part)

Two independent clocks (the DAW's audio clock and the phone's DAC clock) never
run at *exactly* the same rate (±50–200 ppm). Over minutes this causes the
buffer to slowly fill or drain. Plus the network adds jitter (packets arriving
late) and loss. The buffer copes with three regimes:

| Situation | Symptom | Response |
|---|---|---|
| Isolated late/lost packet | one sequence gap | **Opus FEC** rebuilds the frame (inaudible) |
| Phone clock *slower* (buffer grows) | latency creeps up | **overflow trim** → `seekToLatest(_kSteadyBuffer)` |
| Phone clock *faster* (buffer drains) | sustained empty callbacks | **rebuffer**: feed silence, refill, resume at real-time |

This is why playback stays clean for long sessions without a hard sync clock.

---

## 6. The hard problems & how they were solved

- **Clock drift** → the adaptive buffer above (overflow trim + rebuffer). The "proper" fix (continuous drift-resampling) is future work.
- **Network jitter / loss** → jitter-buffer depth + Opus FEC. Deeper buffer = more tolerance but more latency (a direct trade).
- **Discovery over an iPhone Personal Hotspot** → iOS doesn't deliver broadcasts across the hotspot bridge to the app, and sends the app's own broadcasts out cellular. Solved by the app **unicasting** the heartbeat to every `172.20.10.x` client address (see §2.1).
- **Deterministic startup FEC spike** → at stream start the socket often catches the first packet, drops a burst while Flutter/Opus initialise, then catches up — leaving an old "straggler" packet that made the buffer FEC-walk the whole gap. Fixed by `seekToLatest` dropping far stragglers.
- **Clicks on DAW play/pause** → the transport-aware fade in `processBlock`.
- **UI vs audio contention** (see §7) → keep the UI lightweight; throttle/isolate the VU meter.

---

## 7. The fundamental limitation (important for the thesis)

On the app, the **audio playback feed callback runs on the same Dart event loop
as the UI**. `flutter_pcm_sound` uses a *pull* model where Dart refills the
hardware buffer — but Dart pauses for up to ~30 ms doing UI work. To survive
those pauses without the sound cutting out, the hardware buffer must be kept
~60–80 ms deep, and heavy/high-frequency UI work (animations, full-page
rebuilds) steals time from the feed callback and causes underruns.

**Consequences (all the same root cause):**
- **Latency floor ≈ 80 ms** of hardware buffer alone → end-to-end ~150–200 ms. **50 ms is not reachable** with this architecture.
- The VU meter is throttled to ~12 Hz and isolated so it doesn't starve the audio; continuous 60 fps animations were removed for the same reason.

**The single fix for all of it** would be a **native audio pipeline** (Swift on
iOS / Kotlin on Android) that does receive→decode→playback on a dedicated
real-time thread, off the Dart event loop — allowing a ~5 ms hardware buffer and
smooth UI simultaneously. That, plus 2.5 ms Opus frames and drift-resampling, is
the path to sub-50 ms. It's a real rewrite (not a tuning change), and was scoped
as future work.

### Latency budget (current, ~190 ms)
| Stage | ms |
|---|---|
| Opus frame buffering | 10 |
| Opus codec look-ahead | ~6 |
| Network (Wi-Fi/hotspot) | ~5 (+ jitter) |
| Jitter buffer (steady) | ~90 |
| `flutter_pcm_sound` hardware buffer | ~70 |
| OS audio output | ~10 |

---

## 8. Configuration reference (current values)

**Plugin (`AudioStreamManager` / `OpusEncoder`)**
- Opus frame: **480 samples = 10 ms** @ 48 kHz · **256 kbps** · complexity 10 · FEC on
- FIFO capacity: ~100 ms

**App jitter buffer (`audio_manager.dart`, `audio_buffer.dart`)**
| Constant | Value | Meaning |
|---|---|---|
| `kPreBufferPackets` | 6 | packets before playback starts (buffer "ready") |
| `kMaxPackets` | 150 | hard cap (1.5 s) |
| `_kNonWinPreBuffer` | 18 | startup/recovery seek depth (~180 ms, settles to ~90 ms) |
| `_kSteadyBuffer` | 9 | overflow-trim target (~90 ms steady-state latency) |
| `_kOverflowPackets` | 14 | trim when buffer grows past this (drift up) |
| `_kDriftThreshold` | 8 | consecutive empty callbacks → rebuffer (drift down) |
| `kFramesPerFeed` | 4 | frames fed per callback (40 ms) |
| `setFeedThreshold` | 6 × frame | hardware buffer target (~60 ms) |

The single most important knob is **`_kSteadyBuffer`**: lower = less latency but
more loss-concealment on jitter; higher = more stable but more latency.

---

## 9. Build & run

**Plugin** (needs CMake + a C++ toolchain; Opus is fetched/built by CMake):
```
cmake -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build --config Release
# installs VST3 + AU to ~/Library/Audio/Plug-Ins; Standalone in build/.../Standalone
```

**App** (needs Flutter):
```
flutter pub get
flutter run -d <device>          # iOS/Android/macOS/Windows
```

**To use it:** load the plugin on the DAW's master bus → open the app on a phone
on the same Wi-Fi (or the phone's hotspot) → press *Start receiving*. They
auto-connect.

---

## 10. Limitations & future work
- **Latency** bottoms out ~150 ms; sub-50 ms needs the native audio pipeline (§7).
- **Android audio** is implemented but only verified to build/run, not on real hardware (emulator NAT blocks the UDP path).
- **Clock drift** is corrected reactively (rebuffer/trim); drift-resampling would make it seamless.
- The plugin repo still contains **inert DSP-template code** (effect rack / macro system) inherited from the plugin template; it is not used by the streamer.
