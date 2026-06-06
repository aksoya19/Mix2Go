import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import '../network/udp_receiver.dart';
import '../network/discovery_announcer.dart';
import 'audio_buffer.dart';
import 'windows_audio_output.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → jitter buffer → hardware audio output.
///
/// ═══════════════════════════════════════════════════════════════════
///  Data flow (pull model — no timers)
/// ═══════════════════════════════════════════════════════════════════
///   UDP datagram  →  UdpReceiver (Opus decode)
///                 →  ReorderBuffer.add()
///
///   onFeedNeeded  →  _dequeueNextFrame()        (adaptive dequeue)
///                 →  FlutterPcmSound.feed()      (hardware consumes this)
///
/// ═══════════════════════════════════════════════════════════════════
///  Clock drift correction (the ~2-minute degradation bug)
/// ═══════════════════════════════════════════════════════════════════
///   DAW and iPhone audio clocks differ by ±50–200 ppm.  Over ~2 minutes
///   a 100 ppm gap accumulates ~144 ms of relative drift.  If the iPhone
///   plays slightly faster than the DAW sends, the jitter buffer drains
///   chronically — every frame becomes Opus FEC concealment — sounds like
///   1-bit / buzzy artifacts that never recover on their own.
///
///   Fix: adaptive rebuffer mode.
///   • 1–3 consecutive empty CALLBACKS → isolated jitter → Opus FEC (fine).
///   • ≥ _kDriftThreshold consecutive empty CALLBACKS (80 ms sustained)
///     → clock drift detected → enter _rebuffering:
///       stop consuming, feed silence, wait for _kPreBuffer packets
///       to re-accumulate, call seekToLatest(), resume at real-time.
///   • Opposite drift (DAW faster): buffer grows > _kOverflowPackets (150 ms)
///     → trim to real-time via seekToLatest().
///
///   IMPORTANT: the drift counter is updated ONCE per feed callback, NOT
///   once per _dequeueNextFrame() call.  The look-ahead refill loop calls
///   _dequeueNextFrame() 2-3 times per callback, so per-dequeue counting
///   inflated the counter 2-3× and triggered drift detection after only
///   ~30 ms of WiFi jitter (3 empty dequeues = counter 9 > threshold 8)
///   — turning normal WiFi hiccups into 120 ms of forced silence.
///   This was the root cause of the audible stutter.
///
/// ═══════════════════════════════════════════════════════════════════
///  iOS 26 beta Dart stall mitigation
/// ═══════════════════════════════════════════════════════════════════
///   The Dart event loop stalls ≤ 30 ms on UI frames (60 fps × 16.7 ms
///   + method channel overhead).  setFeedThreshold = 8 Opus frames (80 ms)
///   so even a 30 ms stall still leaves 50 ms in the hardware buffer before
///   Dart wakes and feeds 20 ms more — no underrun.
///   Buffer oscillates 80–100 ms.  With 10 ms frames, 120 ms pre-buffer and
///   ~5 ms network, end-to-end latency ≈ 215 ms (10+5+120+80).
///
/// ═══════════════════════════════════════════════════════════════════
///  Pre-buffer depth (startup + drift recovery)
/// ═══════════════════════════════════════════════════════════════════
///   Must cover the hardware fill-burst that fires right after seekToLatest():
///
///    macOS/iOS  flutter_pcm_sound fires callbacks until hardware = threshold
///               (80 ms = 8 pkts).  Each feed = 2 pkts → 4 burst callbacks →
///               min needed = 4×2 + 1 look-ahead = 9.  Use 12 for margin.
///               120 ms startup / max silence per drift correction.
///
///    Windows    WinMM pre-sets all 8 headers to WHDR_DONE in start().
///               First poll fires 8 simultaneous callbacks × 2 pkts = 16 used.
///               min needed = 16 + 1 = 17.  Use 20 for margin.
///               200 ms startup / max silence per drift correction.
///
///   Using only 6 packets here (the OLD default that was wrong) starves the
///   buffer during the startup burst → FEC concealment fires → drift counter
///   spikes → rebuffer mode triggers within seconds of pressing play.
///
/// ═══════════════════════════════════════════════════════════════════
///  Session ID guard (stop/start race)
/// ═══════════════════════════════════════════════════════════════════
///   _sessionId increments on every start().  _initPlayer() snapshots it
///   at entry and checks _stillBuffering() after every await — if stop()
///   raced in, the stale _initPlayer() aborts without touching hardware.
///   _callbackSessionId is set when the feed callback is registered; stale
///   callbacks from the previous session self-abort on the first line of
///   _onFeedNeeded.
class AudioManager {
  final UdpReceiver        _receiver = UdpReceiver();
  final ReorderBuffer      _buffer   = ReorderBuffer();
  final DiscoveryAnnouncer _announcer = DiscoveryAnnouncer();
  WindowsAudioOutput? _winAudio;

  // Cached device IP resolved once per session start (sync getter for UI).
  String _cachedDeviceIP = '';

  // ── Streams ────────────────────────────────────────────────────────────────
  final StreamController<AudioState> _stateCtrl =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _logCtrl =
      StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateCtrl.stream;
  Stream<String>     get logStream   => _logCtrl.stream;

  // ── Core state ─────────────────────────────────────────────────────────────
  bool       _isDisposed   = false;
  AudioState _currentState = AudioState.stopped;
  AudioState get currentState => _currentState;

  // ── Stream parameters — updated from the first received packet ─────────────
  int _numChannels = 2;
  int _numSamples  = 480;   // per channel; 480 samples @ 48 kHz = 10 ms
  int _sampleRate  = 48000;

  // Frame duration in ms (dynamically derived so it's always correct).
  int get _frameDurationMs => _numSamples * 1000 ~/ _sampleRate;

  // ── Feed queue ─────────────────────────────────────────────────────────────
  // Bridges the fixed Opus frame size (480 samples/ch) and the variable
  // hardware block size reported by flutter_pcm_sound.
  final Queue<Int16List> _feedQueue = Queue();

  // ── EOS fade-out ───────────────────────────────────────────────────────────
  bool   _fadingOut = false;
  double _fadeGain  = 1.0;
  // 10 steps × 10 ms/frame × 2 frames/feed = ~100 ms fade
  static const double _kFadeStep = 0.1;

  // ── Session management ─────────────────────────────────────────────────────
  int  _sessionId         = 0;   // incremented on every start()
  int  _callbackSessionId = -1;  // snapshot when callback registered
  bool _isInitializing    = false; // prevents double _initPlayer()
  bool _didSeekToLatest   = false; // seek happens on first feed callback
  bool _needsSettleDelay  = false; // true after release() — iOS AVAudioSession
                                   // needs ~300ms to settle before reinit

  // ── Adaptive jitter buffer / clock drift correction ────────────────────────
  bool _rebuffering             = false;
  int  _consecutiveUnderruns    = 0;
  // Set to true by _dequeueNextFrame() when it returns a real decoded frame.
  // Reset to false at the start of each _onFeedNeeded() call.
  // _consecutiveUnderruns is then updated ONCE per callback (not per dequeue),
  // so the 2-3 look-ahead dequeues don't inflate the counter 2-3×.
  bool _hadRealFrameThisCallback = false;

  // 4 × kFramesPerFeed × frameDurationMs = 4 × 40 ms = 160 ms of sustained
  // all-empty callbacks → clock drift detected (not isolated packet loss).
  // This is COUNTED PER CALLBACK, not per dequeue — see _hadRealFrameThisCallback.
  // Raised to 8: with a deep (~90 ms) buffer, brief jitter bursts ride through
  // on the buffer itself — only a genuine sustained drain triggers rebuffering
  // (which is an audible gap, worse than an FEC tick we want to avoid anyway).
  static const int _kDriftThreshold  = 8;
  // Trim only when drift grows the buffer ~50 ms above steady. Far enough above
  // _kSteadyBuffer(9) that the trim (which clears the feed queue) fires only
  // every several minutes under clock drift, not on normal jitter.
  static const int _kOverflowPackets = 14;
  // Steady-state target the overflow trim / rebuffer-recovery seeks to.
  // 9 packets = 90 ms of jitter absorption — deep enough that hotspot jitter
  // spikes rarely exceed it, so FEC fires only on genuine loss.
  static const int _kSteadyBuffer    = 9; // 90 ms jitter headroom

  // ── Pre-buffer depth (startup + drift recovery) ───────────────────────────
  //
  // See class header for derivation.  The key insight: flutter_pcm_sound /
  // WinMM both fire a BURST of feed callbacks right after the first feed,
  // until the hardware buffer reaches setFeedThreshold.  Each callback
  // dequeues 2 packets, so 4 burst callbacks (macOS/iOS) consume 8 packets
  // + 1 look-ahead = 9 minimum.  Using 12 for margin.
  //
  // One-time startup depth. The hardware fill-burst consumes ~9 packets right
  // after the first feed, so 18 here lands the steady-state buffer at ~9
  // (= _kSteadyBuffer) — deep enough to absorb hotspot jitter so FEC is rare.
  static const int _kNonWinPreBuffer = 18; // 180 ms startup → ~90 ms steady
  static const int _kWinPreBuffer    = 24; // 240 ms startup
  static int get   _kPreBuffer       =>
      Platform.isWindows ? _kWinPreBuffer : _kNonWinPreBuffer;

  // ── Stats ──────────────────────────────────────────────────────────────────
  int       _underruns     = 0;
  int       _totalFedMs    = 0;
  int       _bytesReceived = 0;
  DateTime? _startTime;

  // ── Exposed to UI ──────────────────────────────────────────────────────────
  int    get buffered              => _buffer.buffered;
  double get lossRate              => _buffer.lossRate;
  bool   get isRebuffering        => _rebuffering;
  int    get underruns            => _underruns;
  int    get frameDurationMs      => _frameDurationMs;
  int    get rawDatagramsReceived => _receiver.rawDatagramsReceived;
  int    get validPacketsDecoded  => _receiver.validPacketsDecoded;
  String get lastOpusError        => _receiver.lastOpusError;
  String get lastHeaderInfo       => _receiver.lastHeaderInfo;
  double get bitrateKbps {
    if (_startTime == null) return 0;
    final secs = DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
    return secs > 0 ? (_bytesReceived * 8) / (secs * 1000) : 0;
  }

  /// The actual UDP port the app is listening on (OS-assigned).
  /// Show this to the user so they can enter it in the Mix2Go VST (manual fallback).
  int    get listenPort => _receiver.actualPort;

  /// Cached WiFi IP of this device (prefer en0, updated on every start()).
  String get deviceIP   => _cachedDeviceIP;

  // ══════════════════════════════════════════════════════════════════════════
  // Public API
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> start() async {
    if (_currentState != AudioState.stopped) return;

    // Increment session ID first — invalidates any lingering callbacks.
    _sessionId++;

    _buffer.reset();
    _feedQueue.clear();
    _fadingOut                = false;
    _fadeGain                 = 1.0;
    _isInitializing           = false;
    _didSeekToLatest          = false;
    _rebuffering              = false;
    _consecutiveUnderruns     = 0;
    _hadRealFrameThisCallback = false;
    _underruns                = 0;
    _totalFedMs               = 0;
    _bytesReceived            = 0;
    _startTime                = null;
    _cachedDeviceIP           = '';

    _updateState(AudioState.buffering);
    _log('Binding on UDP port 0 (OS-assigned)...');

    try {
      // Port 0 = OS assigns a free port; read it back via _receiver.actualPort.
      await _receiver.start(
        port:     0,
        onPacket: _handlePacket,
        onEos:    _handleEos,
      );

      // Resolve and cache this device's WiFi IP for display.
      _cachedDeviceIP = await _resolveDeviceIP();

      // Start broadcasting so the VST can auto-discover us.
      await _announcer.start(_receiver.actualPort);

      _log('Listening on port ${_receiver.actualPort}  IP: $_cachedDeviceIP');
    } catch (e) {
      _log('Error starting receiver: $e');
      _updateState(AudioState.error);
    }
  }

  Future<void> stop() async {
    _receiver.stop();
    _announcer.stop();

    if (Platform.isWindows) {
      try { await _winAudio?.release(); } catch (_) {}
      _winAudio = null;
    } else {
      // Swap in a no-op callback BEFORE release so any in-flight native
      // callback that fires during teardown hits a harmless handler.
      try { FlutterPcmSound.setFeedCallback((_) {}); } catch (_) {}
      try { await FlutterPcmSound.release(); } catch (_) {}
      // Mark that the AVAudioSession was deactivated; _initPlayer() will
      // insert a settle delay before the next AudioUnit creation.
      _needsSettleDelay = true;
    }

    _callbackSessionId        = -1;
    _isInitializing           = false;
    _didSeekToLatest          = false;
    _rebuffering              = false;
    _consecutiveUnderruns     = 0;
    _hadRealFrameThisCallback = false;
    _buffer.reset();
    _feedQueue.clear();
    _fadingOut  = false;
    _fadeGain   = 1.0;

    _updateState(AudioState.stopped);
    _log('Stopped.');
  }

  void dispose() {
    _isDisposed = true;
    stop();
    _stateCtrl.close();
    _logCtrl.close();
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Packet / EOS handlers  (called from UDP isolate / Dart event loop)
  // ══════════════════════════════════════════════════════════════════════════

  void _handlePacket(Mix2GoPacket packet) {
    if (_isDisposed) return;

    _bytesReceived += packet.rawBytes;
    _startTime ??= DateTime.now();

    // Update stream parameters from the packet header.
    _numChannels = packet.numChannels;
    _numSamples  = packet.numSamples;
    _sampleRate  = packet.sampleRate;

    _buffer.add(packet.sequenceNumber, packet.samples,
                packet.numSamples, packet.numChannels);

    // Trigger player init once enough packets have accumulated to survive
    // the immediate hardware fill burst.  ReorderBuffer.isReady fires at
    // kPreBufferPackets (6), which is NOT enough on its own — the startup
    // burst dequeues ~9 packets back-to-back, so wait for _kPreBuffer (12)
    // packets before initialising the player.
    // _isInitializing prevents double-init if multiple packets arrive during
    // the async setup awaits.
    if (_currentState == AudioState.buffering &&
        _buffer.buffered >= _kPreBuffer && !_isInitializing) {
      _isInitializing = true;
      _initPlayer(); // unawaited — uses session ID guards internally
    }
  }

  void _handleEos(int seq) {
    if (_isDisposed) return;
    _buffer.markEos();
    if (_buffer.isEosConfirmed && !_fadingOut) {
      _fadingOut = true;
      _log('EOS received — fading out…');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Player initialisation
  // ══════════════════════════════════════════════════════════════════════════

  // Returns false and clears _isInitializing if this session was superseded.
  bool _stillBuffering(int sid) =>
      !_isDisposed && _currentState == AudioState.buffering && _sessionId == sid;

  Future<void> _initPlayer() async {
    final sid = _sessionId; // snapshot — changes if stop()+start() races us

    try {
      // After release(), iOS needs ~300 ms for the AVAudioSession to fully
      // deactivate before a new AudioUnit can be created cleanly.  Without
      // this delay, fast stop→start cycles produce 1-2 s of underruns.
      // The delay is skipped on the very first start (no previous release).
      if (_needsSettleDelay) {
        _needsSettleDelay = false;
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }
        await Future.delayed(const Duration(milliseconds: 300));
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }
      }

      if (Platform.isWindows) {
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }
        _winAudio = WindowsAudioOutput();
        await _winAudio!.setup(sampleRate: _sampleRate, channelCount: _numChannels);
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }
        _callbackSessionId = sid;
        _updateState(AudioState.playing);
        _winAudio!.setFeedCallback(_onFeedNeeded);
        _winAudio!.start();

      } else {
        // iOS / macOS path.
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }

        await FlutterPcmSound.setup(
          sampleRate:              _sampleRate,
          channelCount:            _numChannels,
          iosAllowBackgroundAudio: true,
        );
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }

        // setFeedThreshold unit = audio frames (samples per channel), NOT
        // total Int16 values.  6 × _numSamples = 6 × 10 ms = 60 ms.
        // iOS 26 Dart stalls ≤ 30 ms → after stall, 30 ms still in hardware
        // → Dart wakes and feeds 4 more frames (40 ms) → no underrun.
        // Threshold 60 ms with 40 ms feed → buffer oscillates 60–100 ms.
        // CRITICAL: a higher threshold (8×) causes a longer startup burst that
        // drains the 12-packet jitter buffer before the plugin refills it,
        // triggering rebuffering immediately and creating a permanent loop.
        await FlutterPcmSound.setFeedThreshold(
          _numSamples * 6, // audio frames (per channel), NOT * numChannels
        );
        if (!_stillBuffering(sid)) { _isInitializing = false; return; }

        // Register callback and manually prime the first feed.
        _callbackSessionId = sid;
        _updateState(AudioState.playing);
        FlutterPcmSound.setFeedCallback(_onFeedNeeded);

        // FlutterPcmSound.start() uses a static _needsStart flag that is set
        // to false after the first feed() and is NEVER reset by release().
        // On the second start() within the same app session it silently does
        // nothing, leaving the AudioUnit idle forever.
        //
        // Fix: call _onFeedNeeded(0) directly — same effect as start() on the
        // first run, but works on every subsequent start too.
        _onFeedNeeded(0);
      }

      _log('▶ Playback started'
           '  sr=$_sampleRate  ch=$_numChannels'
           '  frame=${_numSamples}smp/${_frameDurationMs}ms'
           '  threshold=${_numSamples * 6}frm (${_frameDurationMs * 6}ms)'
           '  feed=4pkts/${_frameDurationMs * 4}ms'
           '  pre-buffer=${_kPreBuffer}pkts (${_kPreBuffer * _frameDurationMs}ms)'
           '  backend=${Platform.isWindows ? "waveOut" : "flutter_pcm_sound"}');

    } catch (e) {
      _log('Player init failed: $e');
      _isInitializing = false;
      _updateState(AudioState.error);
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Feed callback  (called by native audio engine)
  // ══════════════════════════════════════════════════════════════════════════

  void _onFeedNeeded(int remainingSamples) {
    // Guard 1: disposed or not in playing state.
    if (_isDisposed || _currentState != AudioState.playing) return;
    // Guard 2: stale callback from a previous session (after stop+start race).
    if (_callbackSessionId != _sessionId) return;

    // First callback: the setup-time packet backlog has accumulated in the
    // buffer (dozens of packets during the async setup awaits).  Discard it
    // and snap to the latest frame so playback starts at real-time.
    // This MUST happen on the first callback, not at init time, because all
    // queued UDP events drain between _initPlayer() and the first callback.
    //
    // Keep _kPreBuffer packets so the immediate hardware fill burst
    // (macOS/iOS: ~4 callbacks back-to-back, Windows: 8 simultaneous polls)
    // consumes real audio instead of FEC silence → no startup clicks/stutter.
    if (!_didSeekToLatest) {
      _didSeekToLatest      = true;
      _rebuffering          = false;
      _consecutiveUnderruns = 0;
      _buffer.seekToLatest(_kPreBuffer);
      _feedQueue.clear();
    }

    // Reset per-callback gap flag.  _dequeueNextFrame() sets this to true
    // when it returns a real decoded frame.  We use it below (after the
    // drain loop) to update _consecutiveUnderruns ONCE per callback rather
    // than once per dequeue — the look-ahead refill calls _dequeueNextFrame
    // 2-3 times per callback, so per-dequeue counting inflated the counter
    // 2-3× and triggered drift detection after only 1-2 empty callbacks
    // (20-40 ms) instead of 4 (80 ms).  THIS WAS THE STUTTER BUG.
    _hadRealFrameThisCallback = false;

    final frameSize = _numSamples * _numChannels; // Int16 values per Opus frame

    // Overflow trim: DAW clock faster than iOS → buffer grows over time.
    // Trim to _kSteadyBuffer (low) — NOT _kPreBuffer — so steady-state latency
    // stays down. This is the fix for the buffer parking at the 120 ms startup
    // depth and never coming back down.
    if (!_rebuffering && _buffer.buffered > _kOverflowPackets) {
      final before = _buffer.buffered;
      _buffer.seekToLatest(_kSteadyBuffer);
      _feedQueue.clear();
      _consecutiveUnderruns = 0;
      _log('Overflow trim: $before→${_buffer.buffered}pkts — drift corrected');
    }

    // Feed 4 Opus frames (40 ms) per callback.
    // Threshold = 6 frames (60 ms), so native buffer oscillates 60–100 ms.
    // 4 frames per feed keeps the startup burst short (only 2 callbacks needed
    // to fill the native buffer) so the 12-packet jitter buffer isn't drained.
    const kFramesPerFeed = 4;
    final feedSize = frameSize * kFramesPerFeed;

    // Refill internal queue to hold kFramesPerFeed+1 frames of look-ahead.
    while (_feedQueue.fold<int>(0, (s, f) => s + f.length) <
           frameSize * (kFramesPerFeed + 1)) {
      _feedQueue.add(_dequeueNextFrame());
    }

    // Drain exactly feedSize Int16 values into the output buffer.
    final out = Int16List(feedSize);
    int pos = 0;
    while (pos < feedSize && _feedQueue.isNotEmpty) {
      final chunk = _feedQueue.first;
      final take  = (feedSize - pos).clamp(0, chunk.length);
      out.setRange(pos, pos + take, chunk);
      _feedQueue.removeFirst();
      if (take < chunk.length) {
        _feedQueue.addFirst(Int16List.sublistView(chunk, take));
      }
      pos += take;
    }

    // ── Per-callback consecutive underrun tracking ─────────────────────────
    // Update ONCE after all dequeue calls so the look-ahead (+1 frame) doesn't
    // count gaps 2-3× per callback.  If ANY real frame arrived this callback,
    // reset the streak.  If ALL dequeues returned FEC/silence, increment.
    if (!_rebuffering) {
      if (_hadRealFrameThisCallback) {
        _consecutiveUnderruns = 0;
      } else {
        _consecutiveUnderruns++;
        if (_consecutiveUnderruns >= _kDriftThreshold) {
          _rebuffering = true;
          _log('⚠ Buffer empty: $_consecutiveUnderruns '
               '× ${_frameDurationMs * kFramesPerFeed}ms empty callbacks '
               '(${_consecutiveUnderruns * _frameDurationMs * kFramesPerFeed}ms total)'
               ' — rebuffering…');
        }
      }
    }

    // EOS fade-out.
    if (_fadingOut) {
      _applyFade(out);
      _fadeGain = (_fadeGain - _kFadeStep).clamp(0.0, 1.0);
      if (_fadeGain <= 0.0) { stop(); return; }
    }

    if (Platform.isWindows) {
      _winAudio?.feed(out);
    } else {
      // Zero-copy: wrap the Int16List buffer view directly.
      // PcmArrayInt16.fromList() does an O(n) element-by-element copy
      // at 100 callbacks/sec → measurable CPU spike → audio starvation.
      FlutterPcmSound.feed(
        PcmArrayInt16(bytes: out.buffer.asByteData(
          out.offsetInBytes, out.lengthInBytes)),
      );
    }

    _totalFedMs += _frameDurationMs * kFramesPerFeed;

    // Log once per second.
    if ((_totalFedMs ~/ 1000) >
        ((_totalFedMs - _frameDurationMs * kFramesPerFeed) ~/ 1000)) {
      _log('buf:${_buffer.buffered}pkts '
           'loss:${(_buffer.lossRate * 100).toStringAsFixed(1)}% '
           'underruns:$_underruns '
           'kbps:${bitrateKbps.toStringAsFixed(0)}'
           '${_rebuffering ? " [REBUFFERING]" : ""}');
    }
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Adaptive dequeue with clock-drift correction
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns the next decoded audio frame.  Never returns null.
  ///
  /// State machine:
  ///   pre-buffer    → silence (hardware keeps running without a click)
  ///   normal        → real frame from buffer, set _hadRealFrameThisCallback
  ///   isolated loss → Opus FEC concealment
  ///   clock drift   → enter _rebuffering (decided in _onFeedNeeded, NOT here);
  ///                   silence until _kPreBuffer packets re-accumulate;
  ///                   seekToLatest(); resume
  ///
  /// NOTE: this function NEVER decides on its own to enter rebuffer mode.
  /// That decision is made in _onFeedNeeded() based on a per-CALLBACK count,
  /// not per-dequeue.  See _hadRealFrameThisCallback for the why.
  Int16List _dequeueNextFrame() {
    final silence = Int16List(_numSamples * _numChannels);

    // ── Rebuffer mode (clock drift recovery) ────────────────────────────────
    if (_rebuffering) {
      if (_buffer.buffered >= _kPreBuffer) {
        // Wait for a healthy buffer (confidence the stream is back), then snap
        // to the LOW steady target — the hardware is still primed from the
        // silence feed, so there's no post-recovery burst to survive.
        _rebuffering          = false;
        _consecutiveUnderruns = 0;
        _buffer.seekToLatest(_kSteadyBuffer);
        _feedQueue.clear(); // flush queued silence so real audio starts next
        _log('✓ Clock drift corrected — resuming at real-time');
      }
      // Feed silence while waiting; hardware stays running without a click.
      return silence;
    }

    // ── Pre-buffer not yet full ──────────────────────────────────────────────
    if (!_buffer.isReady) return silence;

    // ── Normal consume ───────────────────────────────────────────────────────
    final (frame, needsFec) = _buffer.consume();

    if (frame != null) {
      // Signal to _onFeedNeeded that this callback had at least one real frame
      // so it resets _consecutiveUnderruns rather than incrementing it.
      _hadRealFrameThisCallback = true;
      return frame;
    }

    // ── Sequence gap ─────────────────────────────────────────────────────────
    if (needsFec) {
      _underruns++; // total FEC count for stats

      // Isolated packet loss: Opus FEC concealment.
      // MUST use the shared decoder from _receiver (has real packet history).
      // A fresh decoder has no state → produces noise/garbage for FEC.
      final dec = _receiver.opusDecoder;
      if (dec != null && dec.lastPacketDurationMs != null) {
        try { return dec.decode(input: null); } catch (_) {}
      }
    }

    return silence;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Helpers
  // ══════════════════════════════════════════════════════════════════════════

  /// Returns the best IPv4 address of this device.
  /// Prefers en0 (always WiFi on iOS), skips link-local (169.254) and loopback.
  static Future<String> _resolveDeviceIP() async {
    try {
      final interfaces = await NetworkInterface.list(
        type:             InternetAddressType.IPv4,
        includeLinkLocal: false,
        includeLoopback:  false,
      );
      // Pass 1 — en0 (WiFi on iOS/macOS)
      for (final iface in interfaces) {
        if (iface.name != 'en0') continue;
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('169.254.') && !ip.startsWith('127.')) return ip;
        }
      }
      // Pass 2 — any routable address
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (!ip.startsWith('169.254.') && !ip.startsWith('127.')) return ip;
        }
      }
    } catch (e) {
      debugPrint('[AudioManager] IP lookup failed: $e');
    }
    return '';
  }

  void _applyFade(Int16List buf) {
    for (int i = 0; i < buf.length; i++) {
      buf[i] = (buf[i] * _fadeGain).round().clamp(-32768, 32767);
    }
  }

  void _updateState(AudioState state) {
    if (_currentState == state || _isDisposed) return;
    _currentState = state;
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }

  void _log(String msg) {
    debugPrint('[AudioManager] $msg');
    if (!_logCtrl.isClosed) _logCtrl.add(msg);
  }
}
