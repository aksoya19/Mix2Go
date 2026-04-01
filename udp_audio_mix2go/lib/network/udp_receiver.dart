import 'dart:typed_data';
import 'package:udp/udp.dart';

// JUCE Mix2Go protocol — header layout (26 bytes, all little-endian):
//
//   Offset  Size  Type     Field
//   ------  ----  -------  -----
//    0       4    uint32   magic         = 0x4D324730 ("M2G0")
//    4       4    uint32   sampleRate
//    8       2    uint16   numChannels
//   10       4    uint32   numSamples
//   14       8    uint64   timestamp     (µs since stream start — ignored)
//   22       4    uint32   sequenceNumber
//   26       ?    float32  audio data    (interleaved L R L R … in [-1.0, 1.0])
//
// Audio payload size = numSamples * numChannels * 4 bytes.

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

  /// Bind to [port] and call [onPacket] for every valid JUCE audio packet.
  Future<void> start({
    required int port,
    required void Function(JucePacket packet) onPacket,
  }) async {
    if (_isRunning) return;

    try {
      _socket = await UDP.bind(Endpoint.any(port: Port(port)));
      _isRunning = true;
      print('[UDP] Receiver started on port $port');

      _socket!.asStream().listen(
        (datagram) {
          if (datagram == null) return;
          final raw = datagram.data;

          // ── Minimum size check ──────────────────────────────────────────
          if (raw.length < _kHeaderSize) {
            print('[UDP] Packet too short (${raw.length} bytes) — ignored.');
            return;
          }

          // ── Parse header (all little-endian) ────────────────────────────
          final bd = ByteData.sublistView(raw);
          final magic          = bd.getUint32(0,  Endian.little);
          final sampleRate     = bd.getUint32(4,  Endian.little);
          final numChannels    = bd.getUint16(8,  Endian.little);
          final numSamples     = bd.getUint32(10, Endian.little);
          // timestamp at offset 14 (uint64) — read but not used for playback
          final sequenceNumber = bd.getUint32(22, Endian.little);

          // ── Magic check ─────────────────────────────────────────────────
          if (magic != _kMagic) {
            print('[UDP] Wrong magic 0x${magic.toRadixString(16).toUpperCase()} — ignored.');
            return;
          }

          // ── Payload size check ──────────────────────────────────────────
          final expectedBytes = numSamples * numChannels * 4; // 4 bytes per float32
          if (raw.length < _kHeaderSize + expectedBytes) {
            print('[UDP] Payload too short: '
                'got ${raw.length - _kHeaderSize}, expected $expectedBytes bytes');
            return;
          }

          // ── Log every 100 packets ───────────────────────────────────────
          if (sequenceNumber % 100 == 0) {
            print('[UDP] seq=$sequenceNumber  sr=$sampleRate  '
                'ch=$numChannels  samples=$numSamples  '
                'pkt=${raw.length} bytes');
          }

          // ── Extract float32 payload ─────────────────────────────────────
          //
          // IMPORTANT: Float32List.sublistView requires the byte offset to be
          // a multiple of 4 (Float32 alignment). The header is 26 bytes and
          // 26 % 4 == 2, so we CANNOT view in-place. We copy the payload into
          // a fresh 4-byte-aligned Uint8List first.
          //
          final alignedPayload = Uint8List(expectedBytes);
          alignedPayload.setRange(0, expectedBytes, raw, _kHeaderSize);
          final Float32List float32samples = Float32List.sublistView(alignedPayload);

          onPacket(JucePacket(
            sampleRate: sampleRate,
            numChannels: numChannels,
            numSamples: numSamples,
            sequenceNumber: sequenceNumber,
            samples: float32samples,
          ));
        },
        onError: (e) {
          print('[UDP] Stream error: $e');
          stop();
        },
        onDone: () {
          print('[UDP] Stream closed');
          stop();
        },
      );
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
