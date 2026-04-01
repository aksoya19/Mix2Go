import 'dart:typed_data';
import 'package:mp_audio_stream/mp_audio_stream.dart';

/// Thin wrapper around [mp_audio_stream] that supports dynamic sample-rate
/// and channel-count configuration coming from the first received UDP packet.
class AudioPlayerEngine {
  AudioStream? _audioStream;
  bool _isPlayerRunning = false;

  bool get isRunning => _isPlayerRunning;

  /// Initialise the audio output for the given [sampleRate] and [channels].
  ///
  /// Call this once before the first [feedFloat32].  If the stream is already
  /// running, this is a no-op so it is safe to call redundantly.
  Future<void> init({int sampleRate = 44100, int channels = 2}) async {
    if (_isPlayerRunning) return;

    _audioStream ??= getAudioStream();

    try {
      await _audioStream!.init(
        bufferMilliSec:        100,  // 100 ms ring-buffer
        waitingBufferMilliSec: 20,   // start playback after 20 ms of buffered audio
        channels:              channels,
        sampleRate:            sampleRate,
      );
      print('[Player] Initialised: sr=$sampleRate  ch=$channels');
    } catch (e) {
      // mp_audio_stream may throw if already initialised; that is fine.
      print('[Player] init warning (might already be running): $e');
    }
  }

  /// Start the audio output stream.  [sampleRate] and [channels] are forwarded
  /// to [init] so they override any previous (hard-coded) values.
  Future<void> startStream({int sampleRate = 44100, int channels = 2}) async {
    if (_isPlayerRunning) return;
    await init(sampleRate: sampleRate, channels: channels);
    _isPlayerRunning = true;
    print('[Player] Stream started');
  }

  Future<void> stopStream() async {
    _isPlayerRunning = false;
    print('[Player] Stream stopped');
  }

  /// Feed Float32 interleaved samples directly — no conversion needed.
  ///
  /// [samples] must be in the range [-1.0, 1.0] with channel layout
  /// [L0, R0, L1, R1, ...] matching the [channels] passed to [startStream].
  void feedFloat32(Float32List samples) {
    if (!_isPlayerRunning) return;
    _audioStream?.push(samples);
  }

  /// Feed raw PCM-16 LE bytes (used by the built-in sine-wave test path).
  Future<void> feed(Uint8List data) async {
    if (!_isPlayerRunning) return;
    _audioStream?.push(_convertInt16ToFloat32(data));
  }

  Float32List _convertInt16ToFloat32(Uint8List rawData) {
    final int sampleCount = rawData.length ~/ 2;
    final Float32List result = Float32List(sampleCount);
    final ByteData byteData = ByteData.sublistView(rawData);
    for (int i = 0; i < sampleCount; i++) {
      result[i] = byteData.getInt16(i * 2, Endian.little) / 32768.0;
    }
    return result;
  }

  void dispose() {
    _isPlayerRunning = false;
  }
}
