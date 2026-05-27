import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import '../network/udp_receiver.dart';
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
///   • 1–3 consecutive FEC frames → isolated packet loss → Opus FEC (fine).
///   • ≥ 4 consecutive FEC frames (40 ms of sustained empty buffer)
///     → clock drift detected → enter _rebuffering:
///       stop consuming, feed silence, wait for _kRebufferExit (3) packets
///       to re-accumulate, call seekToLatest(), resume at real-time.
///   • Opposite drift (DAW faster): buffer grows > _kOverflowPackets (150 ms)
///     → trim to real-time via seekToLatest().
///
/// ═══════════════════════════════════════════════════════════════════
///  iOS 26 beta Dart stall mitigation
/// ═══════════════════════════════════════════════════════════════════
///   The Dart event loop stalls ≤ 30 ms on UI frames (60 fps × 16.7 ms
///   + method channel overhead).  setFeedThreshold = 8 Opus frames (80 ms)
///   so even a 30 ms stall still leaves 50 ms in the hardware buffer before
///   Dart wakes and feeds 20 ms more — no underrun.
///   Buffer oscillates 80–100 ms.  With 10 ms frames, 40 ms pre-buffer and
///   ~5 ms network, end-to-end latency ≈ 65 ms (10+5+40+10).
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
  final UdpReceiver   _receiver = UdpReceiver();
  final ReorderBuffer _buffer   = ReorderBuffer();
  WindowsAudioOutput? _winAudio;

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
  bool _rebuffering          = false;
  int  _consecutiveUnderruns = 0;

  // 4 × 10 ms = 40 ms of sustained empty buffer → clock drift (not loss).
  // With 10 ms frames, 2 consecutive gaps (20 ms) can occur from normal jitter
  // — too many false positives.  4 gaps (40 ms) matches the old 2×20ms threshold.
  static const int _kDriftThreshold  = 4;
  // Minimum packets before exiting rebuffer.
  // 6 × 10 ms = 60 ms headroom after seekToLatest — enough to survive
  // the next onFeedNeeded draining 3 frames again.
  static const int _kRebufferExit    = 6;
  // Trim buffer to real-time if it grows beyond this many packets (150 ms)
  static const int _kOverflowPackets = 15;

  // ── Stats ──────────────────────────────────────────────────────────────────
  int       _underruns     = 0;
  int       _totalFedMs    = 0;
  int       _bytesReceived = 0;
  DateTime? _startTime;

  // ── Exposed to UI ──────────────────────────────────────────────────────────
  int    get buffered              => _buffer.buffered;
  double get lossRate              => _buffer.lossRate;
  bool   get isRebuffering        => _rebuffering;
  int    get rawDatagramsReceived => _receiver.rawDatagramsReceived;
  int    get validPacketsDecoded  => _receiver.validPacketsDecoded;
  String get lastOpusError        => _receiver.lastOpusError;
  String get lastHeaderInfo       => _receiver.lastHeaderInfo;
  double get bitrateKbps {
    if (_startTime == null) return 0;
    final secs = DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
    return secs > 0 ? (_bytesReceived * 8) / (secs * 1000) : 0;
  }

  // ══════════════════════════════════════════════════════════════════════════
  // Public API
  // ══════════════════════════════════════════════════════════════════════════

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    // Increment session ID first — invalidates any lingering callbacks.
    _sessionId++;

    _buffer.reset();
    _feedQueue.clear();
    _fadingOut            = false;
    _fadeGain             = 1.0;
    _isInitializing       = false;
    _didSeekToLatest      = false;
    _rebuffering          = false;
    _consecutiveUnderruns = 0;
    _underruns            = 0;
    _totalFedMs           = 0;
    _bytesReceived        = 0;
    _startTime            = null;

    _updateState(AudioState.buffering);
    _log('Listening on UDP port $port…');

    try {
      await _receiver.start(
        port: port,
        onPacket: _handlePacket,
        onEos:    _handleEos,
      );
    } catch (e) {
      _log('Error binding port $port: $e');
      _updateState(AudioState.error);
    }
  }

  Future<void> stop() async {
    _receiver.stop();

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

    _callbackSessionId    = -1;
    _isInitializing       = false;
    _didSeekToLatest      = false;
    _rebuffering          = false;
    _consecutiveUnderruns = 0;
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

    // Trigger player init once the pre-buffer is full.
    // _isInitializing prevents double-init if multiple packets arrive during
    // the async setup awaits.
    if (_currentState == AudioState.buffering &&
        _buffer.isReady && !_isInitializing) {
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
        // total Int16 values.  8 × _numSamples = 8 × 10 ms = 80 ms.
        // iOS 26 Dart stalls ≤ 30 ms → after stall, 50 ms still in hardware
        // → Dart wakes and feeds 2 more frames (20 ms) → no underrun.
        // With 10 ms frames a 4× multiplier only gives 40 ms — too close to
        // the 30 ms stall; 8× (80 ms) provides the same safety margin as before.
        await FlutterPcmSound.setFeedThreshold(
          _numSamples * 8, // audio frames (per channel), NOT * numChannels
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
           '  threshold=${_numSamples * 4}frm (${_frameDurationMs * 4}ms)'
           '  pre-buffer=${ReorderBuffer.kPreBufferPackets}pkts (${ReorderBuffer.kPreBufferPackets * _frameDurationMs}ms)'
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
    if (!_didSeekToLatest) {
      _didSeekToLatest      = true;
      _rebuffering          = false;
      _consecutiveUnderruns = 0;
      _buffer.seekToLatest();
      _feedQueue.clear();
    }

    final frameSize = _numSamples * _numChannels; // Int16 values per Opus frame

    // Overflow trim: DAW clock faster than iOS → buffer grows over time.
    // If it exceeds _kOverflowPackets (150 ms), seek to real-time to prevent
    // unbounded latency creep.
    if (!_rebuffering && _buffer.buffered > _kOverflowPackets) {
      final before = _buffer.buffered;
      _buffer.seekToLatest(ReorderBuffer.kPreBufferPackets);
      _feedQueue.clear();
      _consecutiveUnderruns = 0;
      _log('Overflow trim: $before→${_buffer.buffered}pkts — drift corrected');
    }

    // Feed 2 Opus frames (20 ms) per callback.
    // Threshold = 8 frames (80 ms), so native buffer oscillates 80–100 ms.
    const kFramesPerFeed = 2;
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
  ///   normal        → real frame from buffer, reset drift counter
  ///   isolated loss → Opus FEC concealment (1–[_kDriftThreshold-1] gaps)
  ///   clock drift   → enter _rebuffering; silence until [_kRebufferExit]
  ///                   packets re-accumulate; seekToLatest(); resume
  Int16List _dequeueNextFrame() {
    final silence = Int16List(_numSamples * _numChannels);

    // ── Rebuffer mode (clock drift recovery) ────────────────────────────────
    if (_rebuffering) {
      if (_buffer.buffered >= _kRebufferExit) {
        // Enough packets accumulated — snap to real-time and resume.
        _rebuffering          = false;
        _consecutiveUnderruns = 0;
        _buffer.seekToLatest(ReorderBuffer.kPreBufferPackets);
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
      _consecutiveUnderruns = 0; // real frame → reset drift counter
      return frame;
    }

    // ── Sequence gap ─────────────────────────────────────────────────────────
    if (needsFec) {
      _underruns++;
      _consecutiveUnderruns++;

      if (_consecutiveUnderruns >= _kDriftThreshold) {
        // Buffer has been empty for _kDriftThreshold × 10 ms = 40 ms (4 gaps).
        // This is clock drift, not random packet loss.
        _rebuffering = true;
        _log('⚠ Clock drift: ${_consecutiveUnderruns} consecutive gaps '
             '(${_consecutiveUnderruns * _frameDurationMs}ms) — rebuffering…');
        return silence;
      }

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
