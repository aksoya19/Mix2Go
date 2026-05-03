import 'dart:async';
import '../network/udp_receiver.dart';
import 'audio_player.dart';
import 'audio_buffer.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → jitter buffer → audio playback.
///
/// The network receive path only enqueues packets into the [JitterBuffer].
/// A [Timer.periodic] pulls one frame per tick and feeds it to the player,
/// inserting silence for any missing sequence numbers.
class AudioManager {
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

  Timer? _playbackTimer;
  int _consecutiveSilence = 0;

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _playerStarted = false;
    _playerStarting = false;
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
    _playbackTimer?.cancel();
    _playbackTimer = null;
    _jitterBuffer.reset();
    _receiver.stop();
    await _player.stopStream();
    _playerStarted = false;
    _playerStarting = false;
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

  // ── Packet handler (network thread) ──────────────────────────────────────

  void _handlePacket(JucePacket packet) {
    if (_isDisposed) return;

    _jitterBuffer.add(packet);

    // Start the player once the pre-buffer has enough packets to absorb jitter.
    if (!_playerStarted && !_playerStarting && _jitterBuffer.isReady) {
      _playerStarting = true;
      _initPlayer(packet.sampleRate, packet.numChannels, packet.numSamples);
    }
  }

  // ── Playback timer ────────────────────────────────────────────────────────

  void _onPlaybackTick(Timer _) {
    if (!_playerStarted) return;

    final result = _jitterBuffer.consume();
    if (result == null) return;

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

  // ── Player initialisation ─────────────────────────────────────────────────

  Future<void> _initPlayer(int sampleRate, int channels, int numSamples) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);
      _playerStarted = true;

      // Derive the packet duration from the stream parameters and start the
      // output timer. Clamped to [1, 100] ms to guard against bad header values.
      final intervalMs =
          (numSamples * 1000 / sampleRate).round().clamp(1, 100);
      _playbackTimer = Timer.periodic(
        Duration(milliseconds: intervalMs),
        _onPlaybackTick,
      );

      _log(
        'Jitter buffer ready — sr=$sampleRate  ch=$channels  '
        'interval=${intervalMs}ms  '
        'pre-buffer=${JitterBuffer.kPreBufferPackets} packets',
      );
      print('[AudioManager] Player started: sr=$sampleRate  ch=$channels  '
          'timer=${intervalMs}ms');

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
