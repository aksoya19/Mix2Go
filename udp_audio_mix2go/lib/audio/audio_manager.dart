import 'dart:async';
import 'dart:typed_data';
import '../network/udp_receiver.dart';
import 'audio_buffer.dart';
import 'audio_player.dart';

enum AudioState { stopped, buffering, playing, error }

class AudioManager {
  final AudioPlayerEngine _player = AudioPlayerEngine();
  final UdpReceiver _receiver = UdpReceiver();
  final AudioBuffer _buffer = AudioBuffer();

  final StreamController<AudioState> _stateController = StreamController<AudioState>.broadcast();
  final StreamController<String> _logController = StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateController.stream;
  Stream<String> get logStream => _logController.stream;

  Timer? _playbackTimer;
  bool _isDisposed = false;
  
  AudioState _currentState = AudioState.stopped;

  AudioState get currentState => _currentState;

  AudioManager() {
    _player.init();
  }

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _updateState(AudioState.buffering);
    _log("Starting receiver on port $port...");

    try {
      _buffer.clear();
      await _player.startStream();

      await _receiver.start(
        port: port,
        onPacket: (data) {
          _buffer.add(data);
          // If we were buffering and have enough data, switch to playing
          if (_currentState == AudioState.buffering && _buffer.isReadyToPlay) {
            _updateState(AudioState.playing);
            _log("Buffer full, starting playback.");
          }
        },
      );

      _startPlaybackLoop();
      
    } catch (e) {
      _log("Error starting: $e");
      _updateState(AudioState.error);
      stop();
    }
  }

  void _startPlaybackLoop() {
    _playbackTimer?.cancel();
    // We poll the buffer frequently. 
    // Adjust duration to match packet size roughly or be slightly faster.
    // mix2go packets might be ~20ms? Let's check every 5-10ms to be responsive.
    _playbackTimer = Timer.periodic(const Duration(milliseconds: 10), (timer) async {
      if (_isDisposed) {
        timer.cancel();
        return;
      }

      if (_currentState == AudioState.playing) {
        if (_buffer.hasData) {
          final packet = _buffer.next();
          if (packet != null) {
            await _player.feed(packet);
          }
        } else {
          // Underrun: Buffer ran empty.
          _log("Buffer underrun! Buffering...");
          _updateState(AudioState.buffering);
        }
      }
    });
  }

  Future<void> stop() async {
    _playbackTimer?.cancel();
    _receiver.stop();
    await _player.stopStream();
    _buffer.clear();
    _updateState(AudioState.stopped);
    _log("Stopped.");
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
    _stateController.add(state);
  }

  void _log(String message) {
    _logController.add(message);
  }
}
