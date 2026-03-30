import 'dart:typed_data';
import 'package:udp/udp.dart';

// JUCE protocol header layout (26 bytes, little-endian):
//   uint32 magic       = 0x4D324730  ("M2G0")
//   uint32 sampleRate
//   uint16 numChannels
//   uint32 numSamples
//   uint64 timestamp
//   uint32 sequenceNumber
// Followed by:  numSamples * numChannels * float32  (interleaved)

const int _kHeaderSize = 26;
const int _kMagic = 0x4D324730;

class JucePacket {
  final int sampleRate;
  final int numChannels;
  final int numSamples;
  final int sequenceNumber;
  final Float32List samples; // interleaved [L, R, L, R, ...]

  JucePacket({
    required this.sampleRate,
    required this.numChannels,
    required this.numSamples,
    required this.sequenceNumber,
    required this.samples,
  });
}

class UdpReceiver {
  UDP? _socket;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  /// [onPacket] receives a parsed [JucePacket] for every valid UDP frame.
  Future<void> start({
    required int port,
    required void Function(JucePacket packet) onPacket,
  }) async {
    if (_isRunning) return;

    try {
      _socket = await UDP.bind(Endpoint.any(port: Port(port)));
      _isRunning = true;
      print('[UDP] Receiver started on port $port');

      _socket!.asStream().listen((datagram) {
        if (datagram == null) return;
        final raw = datagram.data;

        // --- Minimum size check ---
        if (raw.length < _kHeaderSize) {
          print('[UDP] Packet too short (${raw.length} bytes), ignoring.');
          return;
        }

        // --- Parse header (little-endian) ---
        final bd = ByteData.sublistView(raw);
        final magic          = bd.getUint32(0,  Endian.little);
        final sampleRate     = bd.getUint32(4,  Endian.little);
        final numChannels    = bd.getUint16(8,  Endian.little);
        final numSamples     = bd.getUint32(10, Endian.little);
        // timestamp at offset 14 (uint64) – read but not used
        final sequenceNumber = bd.getUint32(22, Endian.little);

        // --- Magic check ---
        if (magic != _kMagic) {
          print('[UDP] Wrong magic: 0x${magic.toRadixString(16).toUpperCase()} (expected 0x4D324730)');
          return;
        }

        // --- Log every 100 packets so the console stays readable ---
        if (sequenceNumber % 100 == 0) {
          print('[UDP] seq=$sequenceNumber  sr=$sampleRate  ch=$numChannels  samples=$numSamples  bytes=${raw.length}');
        }

        // --- Extract float32 payload ---
        final payloadBytes = raw.length - _kHeaderSize;
        final expectedBytes = numSamples * numChannels * 4; // 4 bytes per float32
        if (payloadBytes < expectedBytes) {
          print('[UDP] Payload too short: got $payloadBytes, expected $expectedBytes bytes');
          return;
        }

        // View payload as Float32 (no copy)
        final float32payload = Float32List.sublistView(
          raw,
          _kHeaderSize,
          _kHeaderSize + expectedBytes,
        );

        onPacket(JucePacket(
          sampleRate: sampleRate,
          numChannels: numChannels,
          numSamples: numSamples,
          sequenceNumber: sequenceNumber,
          samples: float32payload,
        ));
      }, onError: (e) {
        print('[UDP] Stream error: $e');
        stop();
      }, onDone: () {
        print('[UDP] Stream closed');
        stop();
      });
    } catch (e) {
      _isRunning = false;
      throw Exception('Could not bind port $port: $e');
    }
  }

  void stop() {
    if (!_isRunning) return;
    _socket?.close();
    _socket = null;
    _isRunning = false;
    print('[UDP] Receiver stopped');
  }
}
