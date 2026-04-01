import 'dart:async';
import '../network/udp_receiver.dart';
import 'audio_player.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → audio playback.
///
/// The player is initialised *lazily* when the first UDP packet arrives so
/// that the real sample-rate and channel-count reported by the JUCE plugin
/// are used instead of hard-coded defaults.
class AudioManager {
  final AudioPlayerEngine _player = AudioPlayerEngine();
  final UdpReceiver _receiver = UdpReceiver();

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String>     get logStream   => _logController.stream;

  bool _isDisposed = false;
  AudioState _currentState = AudioState.stopped;
  AudioState get currentState => _currentState;

  // Lazy-init flags — player is started on the first received packet.
  bool _playerStarted  = false;
  bool _playerStarting = false;

  // ── Public API ────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _playerStarted  = false;
    _playerStarting = false;

    _updateState(AudioState.buffering);
    _log('Listening on UDP port $port…');

    try {
      await _receiver.start(
        port: port,
        onPacket: _handlePacket,
      );
    } catch (e) {
      _log('Error binding port $port: $e');
      _updateState(AudioState.error);
      await stop();
    }
  }

  Future<void> stop() async {
    _receiver.stop();
    await _player.stopStream();
    _playerStarted  = false;
    _playerStarting = false;
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

  // ── Packet handler (called from UDP listen callback) ──────────────────────

  void _handlePacket(JucePacket packet) {
    if (_isDisposed) return;

    // ── Lazy player initialisation ──────────────────────────────────────────
    if (!_playerStarted) {
      if (!_playerStarting) {
        // First packet — kick off async player init; subsequent packets that
        // arrive while init is in progress are silently dropped (~100 ms max).
        _playerStarting = true;
        _initPlayer(packet.sampleRate, packet.numChannels);
      }
      return; // drop packet while player is initialising
    }

    // ── Feed samples to audio output ────────────────────────────────────────
    _player.feedFloat32(packet.samples);

    if (_currentState == AudioState.buffering) {
      _updateState(AudioState.playing);
    }
  }

  Future<void> _initPlayer(int sampleRate, int channels) async {
    try {
      await _player.startStream(sampleRate: sampleRate, channels: channels);
      _playerStarted = true;
      _log('First packet received — sr=$sampleRate  ch=$channels');
      print('[AudioManager] Player ready: sr=$sampleRate  ch=$channels');
      if (_currentState == AudioState.buffering) {
        _updateState(AudioState.playing);
      }
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
