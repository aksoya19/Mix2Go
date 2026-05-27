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
  bool _isRunning = false;

  // ── Diagnostic counters ───────────────────────────────────────────────────
  int    _rawDatagramsReceived = 0;  // every datagram, before any check
  int    _validPacketsDecoded  = 0;  // after magic + Opus decode success
  String _lastOpusError        = ''; // last decode exception message
  String _lastHeaderInfo       = ''; // header fields from latest packet

  /// Total UDP datagrams received (before magic/Opus checks).
  int get rawDatagramsReceived => _rawDatagramsReceived;

  /// Successfully decoded Opus frames.
  int get validPacketsDecoded => _validPacketsDecoded;

  /// Last Opus decode error (empty if no error yet).
  String get lastOpusError => _lastOpusError;

  /// Header info from the last received packet.
  String get lastHeaderInfo => _lastHeaderInfo;

  bool get isRunning => _isRunning;

  /// Shared Opus decoder — exposed so AudioManager can call
  /// decode(input: null) for FEC concealment on packet gaps.
  /// FEC REQUIRES the same decoder instance that decoded the last real
  /// packet; a fresh decoder produces noise/garbage.
  SimpleOpusDecoder? get opusDecoder => _opusDecoder;

  Future<void> start({
    required int port,
    required void Function(Mix2GoPacket packet) onPacket,
    void Function(int sequenceNumber)? onEos,
  }) async {
    if (_isRunning) return;

    try {
      _socket = await UDP.bind(Endpoint.any(port: Port(port)));
      _isRunning = true;
      print('[UDP] Receiver started on port $port (v2 / Opus)');

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
    _socket = null;
    _opusDecoder?.destroy();
    _opusDecoder = null;
    _isRunning = false;
    _rawDatagramsReceived = 0;
    _validPacketsDecoded  = 0;
    _lastOpusError        = '';
    _lastHeaderInfo       = '';
    print('[UDP] Receiver stopped');
  }

  void _handleDatagram(
    Uint8List raw,
    void Function(Mix2GoPacket) onPacket,
    void Function(int)? onEos,
  ) {
    // ── Raw diagnostic counter (fires before any magic/Opus check) ────────────
    _rawDatagramsReceived++;
    // Log every 1st, 2nd, 3rd, then every 10th so we get quick first-packet
    // confirmation without flooding the console.
    if (_rawDatagramsReceived <= 3 || _rawDatagramsReceived % 10 == 0) {
      print('[UDP] RAW datagram #$_rawDatagramsReceived  len=${raw.length}B');
    }

    if (raw.length < _kHeaderSize) {
      print('[UDP] Too short (${raw.length}B < $_kHeaderSize) — dropped');
      return;
    }

    final bd = ByteData.sublistView(raw);

    final magic            = bd.getUint32(0,  Endian.little);
    final frameTypeByte    = bd.getUint8(4);
    final numChannels      = bd.getUint8(5);
    final payloadLength    = bd.getUint16(6,  Endian.little);
    final sequenceNumber   = bd.getUint32(8,  Endian.little);
    // timestamp @ 12 (8 bytes) — unused
    final sampleRate       = bd.getUint32(20, Endian.little);
    final opusFrameSamples = bd.getUint32(24, Endian.little);

    if (magic != _kMagicV2) {
      print('[UDP] Bad magic 0x${magic.toRadixString(16).padLeft(8, "0")}'
            ' (expected 0x${_kMagicV2.toRadixString(16)}) — dropped');
      return;
    }

    // Log full header for the first 3 magic-valid packets
    if (_rawDatagramsReceived <= 3) {
      final ft = bd.getUint8(4);
      final ch = bd.getUint8(5);
      final pl = bd.getUint16(6, Endian.little);
      final sq = bd.getUint32(8, Endian.little);
      final sr = bd.getUint32(20, Endian.little);
      final fs = bd.getUint32(24, Endian.little);
      final info = 'ft=$ft ch=$ch sr=$sr fs=$fs pl=${pl}B sq=$sq total=${raw.length}B';
      _lastHeaderInfo = info;
      print('[UDP] HDR[$_rawDatagramsReceived] $info');
    }

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

      // Lazily create decoder.
      // Opus only supports output rates 8/12/16/24/48 kHz.
      // The DAW may report 44100 Hz in the header (its input sample rate),
      // but the VST always encodes at 48 kHz internally — so force 48000.
      const int kOpusRate = 48000;
      if (_opusDecoder == null) {
        if (sampleRate != kOpusRate) {
          print('[UDP] Header sampleRate=$sampleRate != 48000 — '
                'forcing decoder to 48000 (Opus only supports 8/12/16/24/48 kHz)');
        }
        _opusDecoder = SimpleOpusDecoder(
          sampleRate: kOpusRate,
          channels: numChannels,
        );
      }

      final payload = Uint8List.sublistView(raw, _kHeaderSize, _kHeaderSize + payloadLength);

      try {
        final Int16List decoded = _opusDecoder!.decode(input: payload);
        _validPacketsDecoded++;

        if (sequenceNumber % 50 == 0) {
          print('[UDP] seq=$sequenceNumber  sr=$sampleRate  ch=$numChannels'
              '  frames=$opusFrameSamples  payload=${payloadLength}B'
              '  total=${raw.length}B  decoded=$_validPacketsDecoded');
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
        _lastOpusError = e.toString().replaceAll('\n', ' ');
        print('[UDP] Opus decode error seq=$sequenceNumber: $e');
      }

      return;
    }

    // Unsupported frame type — silently drop
    print('[UDP] Unknown frameType=$frameTypeByte — ignored');
  }
}
