import 'dart:async';
import 'dart:typed_data';
import 'package:mp_audio_stream/mp_audio_stream.dart';

class AudioPlayerEngine {
  // Use mp_audio_stream for multi-platform raw PCM playback (including Windows)
  // According to pub.dev/packages/mp_audio_stream
  AudioStream? _audioStream;
  bool _isPlayerRunning = false;

  Future<void> init() async {
     // Only initialize if not already done
     if (_audioStream == null) {
       _audioStream = getAudioStream();
     }
     
     // specific init settings call might be needed every time or just once?
     // usually once is enough, but if stopped/disposed we might need to re-init.
     // For safety, we call init() on the stream. mp_audio_stream seems to handle re-init or we can catch error.
     // Better safe:
     try {
       await _audioStream!.init(
         bufferMilliSec: 100, 
         waitingBufferMilliSec: 20,
         channels: 2,
         sampleRate: 44100,
       );
     } catch (e) {
       // If already initialized, it might throw, or just ignore.
       print("AudioStream init warning: $e");
     }
  }

  Future<void> startStream() async {
    if (_isPlayerRunning) return;
    await init();
    _isPlayerRunning = true;
  }

  Future<void> stopStream() async {
    // mp_audio_stream doesn't simple 'stop', but we can stop feeding it.
    // or uninit if available. 
    // _audioStream.uninit(); is not clearly documented in old versions, but let's just stop feeding.
    _isPlayerRunning = false;
  }

  /// Feed raw PCM16 bytes (Int16 little-endian) – used by the sine-wave test path.
  Future<void> feed(Uint8List data) async {
    if (!_isPlayerRunning) return;
    _audioStream?.push(_convertInt16ToFloat32(data));
  }

  /// Feed Float32 samples directly – used by the JUCE UDP path.
  /// [samples] must be interleaved [L, R, L, R, ...] in the range [-1.0, 1.0].
  void feedFloat32(Float32List samples) {
    if (!_isPlayerRunning) return;
    _audioStream?.push(samples);
  }

  // Convert raw bytes (Int16) to Float32 (-1.0 to 1.0)
  Float32List _convertInt16ToFloat32(Uint8List rawData) {
    // Ensure we have pairs of bytes
    final int sampleCount = rawData.length ~/ 2;
    final Float32List result = Float32List(sampleCount);
    final ByteData byteData = ByteData.sublistView(rawData);

    for (int i = 0; i < sampleCount; i++) {
        // Read Int16
        final int sample = byteData.getInt16(i * 2, Endian.little);
        // Normalize to -1.0 .. 1.0
        result[i] = sample / 32768.0;
    }
    return result;
  }

  void dispose() {
    _isPlayerRunning = false;
    // _audioStream.uninit(); if available
  }
}
