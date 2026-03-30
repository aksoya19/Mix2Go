import 'dart:math';
import 'dart:typed_data';

class AudioSource {
  static const int sampleRate = 44100; 
  static const int packetDurationMs = 20; // 20ms packets

  Uint8List getNextPacket() {
    final samples = sampleRate * packetDurationMs ~/ 1000; // 882 Samples pro Paket
    final pcm = Int16List(samples * 2); // 16Bit pro Sample

    for (int i = 0; i < samples; i++) { // für jeden Sample
      final t = i / sampleRate; 
      final value = (sin(2 * pi * 440 * t) * 32767).toInt(); //

      pcm[i * 2] = value;
      pcm[i * 2 + 1] = value;
    }

    return pcm.buffer.asUint8List();
  }
}
