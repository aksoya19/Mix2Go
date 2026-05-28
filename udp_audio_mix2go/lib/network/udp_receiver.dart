import 'dart:typed_data';
import 'package:udp/udp.dart';
import 'package:opus_dart/opus_dart.dart';

// Mix2Go v2 protocol — header layout (28 bytes, all little-endian):
//
//   Offset  Size  Type    Field              Notes
//   ------  ----  ------  -----------------  --------------------------------
//   0       4     uint32  magic              0x4D324731 ("M2G1")
//   4       1     uint8   frameType          0=Opus  1=PCM16  2=EOS
//   5       1     uint8   numChannels        2 = stereo
//   6       2     uint16  payloadLength      byte count of Opus payload
//   8       4     uint32  sequenceNumber
//   12      8     uint64  timestamp          µs since stream start (unused)
//   20      4     uint32  sampleRate         always 48000 in v2
//   24      4     uint32  opusFrameSamples   960 = 20 ms at 48 kHz
//   28      N     bytes   payload            Opus bitstream or empty (EOS)

const int _kHeaderSize = 28;
const int _kMagicV2    = 0x4D324731; // "M2G1"

enum FrameType { opus, pcm16, eos }

class Mix2GoPacket {
  final int       sequenceNumber;
  final FrameType frameType;
  final Int16List samples;     // Int16 interleaved L R L R (empty for EOS)
  final int       sampleRate;
  final int       numChannels;
  final int       numSamples;  // decoded frame size in samples per channel
  final int       rawBytes;    // total UDP datagram size for bitrate stats

  const Mix2GoPacket({
    required this.sequenceNumber,
    required this.frameType,
    required this.samples,
    required this.sampleRate,
    required this.numChannels,
    required this.numSamples,
    required this.rawBytes,
  });
}

class UdpReceiver {
  UDP? _socket;
  SimpleOpusDecoder? _opusDecoder;
  bool _isRunning   = false;
  int  _actualPort  = 0;

  bool get isRunning   => _isRunning;

  /// The port the OS actually bound to (may differ from the requested port
  /// when port=0 is passed and the OS assigns a free port).
  int  get actualPort  => _actualPort;

  /// Shared Opus decoder — exposed so AudioManager can call
  /// decode(input: null) for FEC concealment on packet gaps.
  /// FEC REQUIRES the same decoder instance that decoded the last real
  /// packet; a fresh decoder produces noise/garbage.
  SimpleOpusDecoder? get opusDecoder => _opusDecoder;

  /// [port] = 0 → OS picks any free port (zero collision risk).
  /// After a successful bind, [actualPort] holds the real port number.
  Future<void> start({
    int port = 0,
    required void Function(Mix2GoPacket packet) onPacket,
    void Function(int sequenceNumber)? onEos,
  }) async {
    if (_isRunning) return;

    try {
      _socket = await UDP.bind(Endpoint.any(port: Port(port)));
      // The UDP package wraps a RawDatagramSocket; .port gives the real
      // OS-assigned port (essential when port=0 was requested).
      _actualPort = _socket!.socket?.port ?? port;
      _isRunning  = true;
      print('[UDP] Receiver started on port $_actualPort (v2 / Opus)');

      _socket!.asStream().listen(
        (datagram) {
          if (datagram == null) return;
          _handleDatagram(datagram.data, onPacket, onEos);
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
    _socket      = null;
    _opusDecoder?.destroy();
    _opusDecoder = null;
    _isRunning   = false;
    _actualPort  = 0;
    print('[UDP] Receiver stopped');
  }

  void _handleDatagram(
    Uint8List raw,
    void Function(Mix2GoPacket) onPacket,
    void Function(int)? onEos,
  ) {
    if (raw.length < _kHeaderSize) return;

    final bd = ByteData.sublistView(raw);

    final magic            = bd.getUint32(0,  Endian.little);
    final frameTypeByte    = bd.getUint8(4);
    final numChannels      = bd.getUint8(5);
    final payloadLength    = bd.getUint16(6,  Endian.little);
    final sequenceNumber   = bd.getUint32(8,  Endian.little);
    // timestamp @ 12 (8 bytes) — unused
    final sampleRate       = bd.getUint32(20, Endian.little);
    final opusFrameSamples = bd.getUint32(24, Endian.little);

    if (magic != _kMagicV2) return;

    final frameType = FrameType.values.elementAtOrNull(frameTypeByte)
        ?? FrameType.opus;

    // ── EOS ───────────────────────────────────────────────────────────────────
    if (frameType == FrameType.eos) {
      if (sequenceNumber % 50 == 0 || payloadLength == 0) {
        print('[UDP] EOS received  seq=$sequenceNumber');
      }
      onEos?.call(sequenceNumber);
      return;
    }

    // ── Opus ──────────────────────────────────────────────────────────────────
    if (frameType == FrameType.opus) {
      if (payloadLength == 0 || raw.length < _kHeaderSize + payloadLength) {
        print('[UDP] Opus packet too short — ignored');
        return;
      }

      // Lazily create decoder when we know sampleRate / numChannels
      _opusDecoder ??= SimpleOpusDecoder(
        sampleRate: sampleRate,
        channels: numChannels,
      );

      final payload = Uint8List.sublistView(raw, _kHeaderSize, _kHeaderSize + payloadLength);

      try {
        final Int16List decoded = _opusDecoder!.decode(input: payload);

        if (sequenceNumber % 50 == 0) {
          print('[UDP] seq=$sequenceNumber  sr=$sampleRate  ch=$numChannels'
              '  frames=$opusFrameSamples  payload=${payloadLength}B'
              '  total=${raw.length}B');
        }

        onPacket(Mix2GoPacket(
          sequenceNumber: sequenceNumber,
          frameType:      FrameType.opus,
          samples:        decoded,
          sampleRate:     sampleRate,
          numChannels:    numChannels,
          numSamples:     opusFrameSamples,
          rawBytes:       raw.length,
        ));
      } catch (e) {
        print('[UDP] Opus decode error seq=$sequenceNumber: $e');
      }

      return;
    }

    // Unsupported frame type — silently drop
    print('[UDP] Unknown frameType=$frameTypeByte — ignored');
  }
}
