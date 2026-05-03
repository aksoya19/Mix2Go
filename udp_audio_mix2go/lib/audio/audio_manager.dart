import 'dart:async';
import '../network/udp_receiver.dart';
import 'audio_player.dart';
import 'audio_buffer.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → jitter buffer → audio playback.
///
/// Consumption is driven by a [Timer.periodic] that ticks at the sender's
/// packet rate (e.g. 5 ms for 220 samples @ 44100 Hz).  The network receive
/// path only enqueues packets and tracks the latest sequence number — it never
/// pushes audio directly.  This decouples the output rate from network jitter,
/// preventing the burst-then-starve pattern that occurs over WireGuard/Tailscale
/// tunnels.
class AudioManager {
  // Jitter window: consume up to (latestSeq - _kWindowAhead) per tick so that
  // packets arriving up to this many slots late are still served in order.
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

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _playerStarted = false;
    _playerStarting = false;
    _latestSeq = null;
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

  // ── Packet handler ────────────────────────────────────────────────────────

  void _handlePacket(JucePacket packet) {
    if (_isDisposed) return;

    _latestSeq = packet.sequenceNumber;
    _jitterBuffer.add(packet);

    // Start the player once the pre-buffer is filled.
    if (!_playerStarted && !_playerStarting && _jitterBuffer.isReady) {
      _playerStarting = true;
      _initPlayer(packet.sampleRate, packet.numChannels, packet.numSamples);
    }
  }

  // ── Timer-driven drain ────────────────────────────────────────────────────

  void _onDrainTick(Timer _) {
    final latest = _latestSeq;
    if (latest == null) return;
    _drainUpTo(latest - _kWindowAhead);
  }

  /// Feed all buffered frames whose sequence number is ≤ [maxSeq] to the
  /// audio player.  Gaps in the sequence are filled with silence.
  void _drainUpTo(int maxSeq) {
    while (true) {
      final next = _jitterBuffer.nextExpectedSeq;
      if (next == null || next > maxSeq) break;

      final result = _jitterBuffer.consume();
      if (result == null) break;

      final (samples, wasSilent) = result;
      _player.feedFloat32(samples);

      if (wasSilent) {
        _consecutiveSilence++;
        if (_consecutiveSilence == 1 || _consecutiveSilence % 50 == 0) {
          _log(
            'Packet loss — loss rate: '
            '${(_jitterBuffer.lossRate * 100).toStringAsFixed(1)}%  '
            'buffered: ${_jitterBuffer.buffered}',
          );
        }
      } else {
        _consecutiveSilence = 0;
      }
    }
  }

  // ── Player initialisation ─────────────────────────────────────────────────

  Future<void> _initPlayer(int sampleRate, int channels, int numSamples) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);

      // Discard any backlog that piled up during async init so that
      // _nextSeq aligns with the live receive position.
      if (_latestSeq != null) {
        _jitterBuffer.syncToSeq(_latestSeq! - _kWindowAhead);
      }

      _playerStarted = true;

      final intervalMs = (numSamples * 1000 / sampleRate).round().clamp(1, 100);
      _drainTimer = Timer.periodic(
        Duration(milliseconds: intervalMs),
        _onDrainTick,
      );

      _log(
        'Jitter buffer ready — sr=$sampleRate  ch=$channels  '
        'interval=${intervalMs}ms  window=$_kWindowAhead packets',
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
    print('[AudioManager] $message');
    if (!_logController.isClosed) _logController.add(message);
  }
}
