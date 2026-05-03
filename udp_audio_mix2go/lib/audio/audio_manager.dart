import 'dart:async';
import '../network/udp_receiver.dart';
import 'audio_player.dart';
import 'audio_buffer.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → jitter buffer → audio playback.
///
/// Playback is driven by the packet arrival rate, not by a timer.
/// Each incoming packet triggers a drain of the jitter buffer up to
/// (latestSeq - _kWindowAhead), so [mp_audio_stream]'s ring buffer is
/// filled at exactly the network rate with no platform timer dependency.
class AudioManager {
  // Jitter window: how many packets behind the receive frontier we consume.
  // Packets arriving up to this many slots late are still served in order.
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
      _initPlayer(packet.sampleRate, packet.numChannels);
      return;
    }

    if (_playerStarted) {
      _drainUpTo(packet.sequenceNumber - _kWindowAhead);
    }
  }

  // ── Arrival-driven drain ──────────────────────────────────────────────────

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

  Future<void> _initPlayer(int sampleRate, int channels) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);

      // Discard any backlog that piled up during async init so that
      // _nextSeq aligns with the live receive position.
      if (_latestSeq != null) {
        _jitterBuffer.syncToSeq(_latestSeq! - _kWindowAhead);
      }

      _playerStarted = true;
      _log(
        'Jitter buffer ready — sr=$sampleRate  ch=$channels  '
        'window=$_kWindowAhead packets',
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
