import 'dart:async';
import 'package:flutter/foundation.dart';
import '../network/udp_receiver.dart';
import 'audio_player.dart';
import 'audio_buffer.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → jitter buffer → audio playback.
///
/// Pipeline:
///   UDP callback  →  JitterBuffer.add()        (enqueue only, no audio output)
///   Timer tick    →  consume exactly 1 packet  (feed ring buffer at steady rate)
///
/// Consuming exactly one packet per tick — never more — ensures that a
/// Tailscale/WireGuard burst (N packets delivered simultaneously) is spread
/// over N ticks instead of being flushed into mp_audio_stream all at once.
class AudioManager {
  // Jitter window: consume sequence number N only after packet N+kWindowAhead
  // has arrived, giving that many packets of reorder tolerance.
  static const int _kWindowAhead = 3;

  final AudioPlayerEngine _player = AudioPlayerEngine();
  final UdpReceiver _receiver = UdpReceiver();
  final JitterBuffer _jitterBuffer = JitterBuffer();

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get logStream => _logController.stream;

  bool _isDisposed = false;
  AudioState _currentState = AudioState.stopped;
  AudioState get currentState => _currentState;

  bool _playerStarted = false;
  bool _playerStarting = false;
  int? _latestSeq;
  int _consecutiveSilence = 0;

  Timer? _drainTimer;

  // Diagnostic counters reset on each start.
  int _underruns = 0;   // ticks where the window was not open (no real frame fed)
  int _tickCount = 0;   // total drain-timer ticks since playback began

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _playerStarted = false;
    _playerStarting = false;
    _latestSeq = null;
    _underruns = 0;
    _tickCount = 0;
    _consecutiveSilence = 0;
    _jitterBuffer.reset();

    _updateState(AudioState.buffering);
    _log('Listening on UDP port $port…');

    try {
      await _receiver.start(port: port, onPacket: _handlePacket);
    } catch (e) {
      _log('Error binding port $port: $e');
      _updateState(AudioState.error);
      await stop();
    }
  }

  Future<void> stop() async {
    _drainTimer?.cancel();
    _drainTimer = null;
    _jitterBuffer.reset();
    _receiver.stop();
    await _player.stopStream();
    _playerStarted = false;
    _playerStarting = false;
    _latestSeq = null;
    _consecutiveSilence = 0;
    _updateState(AudioState.stopped);
    _log('Stopped.');
  }

  void dispose() {
    _isDisposed = true;
    _drainTimer?.cancel();
    _drainTimer = null;
    stop();
    _player.dispose();
    _stateController.close();
    _logController.close();
  }

  // ── Packet handler (UDP callback) ─────────────────────────────────────────

  void _handlePacket(JucePacket packet) {
    if (_isDisposed) return;

    _latestSeq = packet.sequenceNumber;
    _jitterBuffer.add(packet);

    // Start the player once the pre-buffer threshold is reached.
    if (!_playerStarted && !_playerStarting && _jitterBuffer.isReady) {
      _playerStarting = true;
      _initPlayer(packet.sampleRate, packet.numChannels, packet.numSamples);
    }
  }

  // ── Timer-driven drain (exactly one packet per tick) ──────────────────────

  void _onDrainTick(Timer _) {
    if (!_playerStarted) return;
    _tickCount++;

    final latest = _latestSeq;
    final nextSeq = _jitterBuffer.nextExpectedSeq;

    // Only consume when the jitter window is open: we need to have seen a
    // packet at least _kWindowAhead ahead of nextSeq before committing to it
    // (or calling it lost).  This gives reordered packets time to arrive.
    final windowOpen = latest != null &&
        nextSeq != null &&
        nextSeq <= latest - _kWindowAhead;

    if (windowOpen) {
      final result = _jitterBuffer.consume(); // never null when window is open
      if (result != null) {
        final (samples, wasSilent) = result;
        _player.feedFloat32(samples);

        if (wasSilent) {
          _consecutiveSilence++;
          if (_consecutiveSilence == 1 || _consecutiveSilence % 50 == 0) {
            _log(
              'Gap — loss: ${(_jitterBuffer.lossRate * 100).toStringAsFixed(1)}%  '
              'buf: ${_jitterBuffer.buffered} pkts',
            );
          }
        } else {
          _consecutiveSilence = 0;
        }

        // Periodic buffer-level log (every ~1 s at 5 ms/tick = 200 ticks).
        if (_tickCount % 200 == 0) {
          _log(
            'buf: ${_jitterBuffer.buffered} pkts  '
            'loss: ${(_jitterBuffer.lossRate * 100).toStringAsFixed(1)}%  '
            'underruns: $_underruns',
          );
        }
        return;
      }
    }

    // Window not yet open (e.g. jitter stall) or buffer genuinely empty.
    // Feed silence so the ring buffer does not starve.
    _underruns++;
    final frameSize = _jitterBuffer.silenceFrameSize;
    if (frameSize > 0) {
      _player.feedFloat32(Float32List(frameSize));
    }
    if (_underruns == 1 || _underruns % 50 == 0) {
      _log(
        'Underrun #$_underruns — window open: $windowOpen  '
        'buf: ${_jitterBuffer.buffered}  '
        'nextSeq: $nextSeq  latest: $latest',
      );
    }
  }

  // ── Player initialisation ─────────────────────────────────────────────────

  Future<void> _initPlayer(int sampleRate, int channels, int numSamples) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);

      // Discard the startup backlog — align _nextSeq to the live position so
      // the first timer tick is close to the current receive frontier.
      if (_latestSeq != null) {
        _jitterBuffer.syncToSeq(_latestSeq! - _kWindowAhead);
      }

      _playerStarted = true;

      // Tick at the sender's packet rate so consumption matches production.
      final intervalMs =
          (numSamples * 1000 / sampleRate).round().clamp(1, 100);
      _drainTimer = Timer.periodic(
        Duration(milliseconds: intervalMs),
        _onDrainTick,
      );

      _log(
        'Playback started — sr=$sampleRate  ch=$channels  '
        'tick=${intervalMs}ms  window=$_kWindowAhead pkts  '
        'pre-buffer=${JitterBuffer.kPreBufferPackets} pkts',
      );
      _updateState(AudioState.playing);
    } catch (e) {
      _log('Player init failed: $e');
      _updateState(AudioState.error);
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  void _updateState(AudioState state) {
    if (_currentState == state || _isDisposed) return;
    _currentState = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  void _log(String message) {
    debugPrint('[AudioManager] $message');
    if (!_logController.isClosed) _logController.add(message);
  }
}
