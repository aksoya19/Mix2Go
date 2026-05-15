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
  // Jitter window: consume sequence number N only after packet N+_kWindowAhead
  // has arrived, giving that many packets of reorder tolerance (5 pkts = 25ms).
  static const int _kWindowAhead = 5;
  // How many extra packets to keep above the window after sync.
  // Buffer after sync = _kWindowAhead + _kSyncMargin + 1 ≈ 21 packets.
  static const int _kSyncMargin = 15;
  // Target buffer for drift correction.
  static const int _kTargetBuffer = 15;

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
  int _underruns = 0;      // ticks where the window was not open (no real frame fed)
  int _tickCount = 0;      // total drain-timer ticks since playback began
  int _driftCheckTick = 0; // counter for periodic drift correction

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _playerStarted = false;
    _playerStarting = false;
    _latestSeq = null;
    _underruns = 0;
    _tickCount = 0;
    _driftCheckTick = 0;
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

    // Drift correction: every 100 ticks (~0.5 s) check the buffer level and
    // nudge consumption to keep it near _kTargetBuffer.
    _driftCheckTick++;
    if (_driftCheckTick >= 100) {
      _driftCheckTick = 0;
      final level = _jitterBuffer.buffered;
      if (level > _kTargetBuffer + 10) {
        // Buffer overfilling → consume one extra packet to drain toward target.
        final extra = _jitterBuffer.consume();
        if (extra != null) _player.feedFloat32(extra.$1);
      } else if (level < _kWindowAhead && level > 0) {
        // Buffer dangerously low → skip one consumption tick so incoming
        // packets can replenish before we advance nextSeq further.
        _underruns++;
        final plcFrame = _jitterBuffer.lastValidFrame;
        _player.feedFloat32(
          plcFrame != null
              ? Float32List.fromList(plcFrame)
              : Float32List(_jitterBuffer.silenceFrameSize),
        );
        return;
      }
    }

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

    // Window closed or buffer too shallow — feed PLC frame WITHOUT calling
    // consume(), so nextSeq does not advance and the buffer can recover.
    _underruns++;
    final plcFrame = _jitterBuffer.lastValidFrame;
    final frameSize = _jitterBuffer.silenceFrameSize;
    if (frameSize > 0) {
      _player.feedFloat32(
        plcFrame != null
            ? Float32List.fromList(plcFrame)
            : Float32List(frameSize),
      );
    }
    if (_underruns == 1 || _underruns % 50 == 0) {
      _log(
        'Underrun #$_underruns — window: $windowOpen  '
        'buf: ${_jitterBuffer.buffered}  '
        'nextSeq: $nextSeq  latest: $latest',
      );
    }
  }

  // ── Player initialisation ─────────────────────────────────────────────────

  Future<void> _initPlayer(int sampleRate, int channels, int numSamples) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);

      // Sync nextSeq to keep _kWindowAhead + _kSyncMargin packets of headroom.
      // Previously this left only _kWindowAhead+1 packets → window was always
      // at its boundary → ~50% of ticks triggered PLC → constant noise layer.
      if (_latestSeq != null) {
        _jitterBuffer.syncToSeq(_latestSeq! - _kWindowAhead - _kSyncMargin);
      }

      _playerStarted = true;

      // Tick at the sender's packet rate using microsecond precision to avoid
      // the ~1 ms rounding error that causes long-term buffer drain at 5 ms/pkt.
      final intervalUs =
          (numSamples * 1000000 ~/ sampleRate).clamp(1000, 100000);
      _drainTimer = Timer.periodic(
        Duration(microseconds: intervalUs),
        _onDrainTick,
      );

      _log(
        'Playback started — sr=$sampleRate  ch=$channels  '
        'tick=$intervalUs µs  window=$_kWindowAhead pkts  '
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
