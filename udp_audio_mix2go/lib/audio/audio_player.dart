import 'dart:typed_data';
import 'package:flutter_sound/flutter_sound.dart';

class AudioPlayerEngine {
  final FlutterSoundPlayer _player = FlutterSoundPlayer();

  Future<void> init() async {
    await _player.openPlayer();
    await _player.setVolume(1.0);
  }

  Future<void> play(Uint8List pcmData) async {
    await _player.startPlayer(
      fromDataBuffer: pcmData,
      codec: Codec.pcm16,
      sampleRate: 44100,
      numChannels: 2,
    );
  }

  void dispose() {
    _player.closePlayer();
  }
}
