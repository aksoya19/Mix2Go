import 'dart:async';
import '../network/udp_receiver.dart';
import 'audio_player.dart';

enum AudioState { stopped, buffering, playing, error }

class AudioManager {
  final AudioPlayerEngine _player = AudioPlayerEngine();
  final UdpReceiver _receiver = UdpReceiver();

  final StreamController<AudioState> _stateController =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _logController =
      StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get logStream => _logController.stream;

  bool _isDisposed = false;
  AudioState _currentState = AudioState.stopped;
  AudioState get currentState => _currentState;

  AudioManager() {
    _player.init();
  }

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _updateState(AudioState.buffering);
    _log('Starting receiver on port $port...');

    bool firstPacket = true;

    try {
      await _player.startStream();

      await _receiver.start(
        port: port,
        onPacket: (packet) {
          if (_isDisposed) return;

          // Log first packet so we can confirm data is flowing
          if (firstPacket) {
            firstPacket = false;
            final msg =
                'First packet received — sr=${packet.sampleRate}  ch=${packet.numChannels}  samples=${packet.numSamples}';
            _log(msg);
            print('[AudioManager] $msg');
          }

          // Feed Float32 directly — no PCM16 conversion, no buffer polling needed
          _player.feedFloat32(packet.samples);

          // Switch to playing on first real data
          if (_currentState == AudioState.buffering) {
            _updateState(AudioState.playing);
          }
        },
      );
    } catch (e) {
      _log('Error starting: $e');
      _updateState(AudioState.error);
      await stop();
    }
  }

  Future<void> stop() async {
    _receiver.stop();
    await _player.stopStream();
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

  void _updateState(AudioState state) {
    if (_currentState == state) return;
    _currentState = state;
    if (!_stateController.isClosed) _stateController.add(state);
  }

  void _log(String message) {
    if (!_logController.isClosed) _logController.add(message);
  }
}
