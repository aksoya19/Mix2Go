import 'dart:collection';
import 'dart:typed_data';
import '../network/udp_receiver.dart';

/// Sequence-ordered jitter buffer for [JucePacket]s.
///
/// Decouples the network receive rate from the audio output rate.
/// Missing sequence numbers are replaced with silence frames so the
/// downstream audio stream never starves.
class JitterBuffer {
  /// Packets to accumulate before allowing [consume] to return data.
  /// 10 packets × 5 ms = 50 ms of pre-roll before playback starts.
  static const int kPreBufferPackets = 10;

  /// Hard cap on buffered packets — oldest is evicted on overflow.
  /// 150 packets × 5 ms = 750 ms of buffer headroom.
  static const int kMaxPackets = 150;

  final SplayTreeMap<int, JucePacket> _map = SplayTreeMap();

  int? _nextSeq;
  int _lostPackets = 0;
  int _totalConsumed = 0;
  bool _ready = false;
  Float32List? _lastValidFrame;

  // Cached from the last received packet — used to size silence frames.
  int _numSamples = 512;
  int _numChannels = 2;

  /// Enqueue a received [packet].
  void add(JucePacket packet) {
    _numSamples = packet.numSamples;
    _numChannels = packet.numChannels;

    if (_map.length >= kMaxPackets) {
      _map.remove(_map.firstKey()); // evict oldest on overflow
    }
    _map[packet.sequenceNumber] = packet;
    _nextSeq ??= packet.sequenceNumber;

    if (!_ready && _map.length >= kPreBufferPackets) _ready = true;
  }

  /// True once [kPreBufferPackets] have been received.
  bool get isReady => _ready;

  /// The next sequence number that [consume] will look for.
  int? get nextExpectedSeq => _nextSeq;

  /// Packets currently held in the buffer.
  int get buffered => _map.length;

  /// Size of a silence frame matching the current stream parameters.
  /// Used by the drain timer to keep the ring buffer fed during underruns.
  int get silenceFrameSize => _numSamples * _numChannels;

  /// Last successfully decoded audio frame, used for packet-loss concealment.
  Float32List? get lastValidFrame => _lastValidFrame;

  /// Fraction of consumed slots filled with silence (0.0–1.0).
  double get lossRate =>
      _totalConsumed == 0 ? 0.0 : _lostPackets / _totalConsumed;

  /// Returns the next audio frame and whether it is silence.
  ///
  /// Returns `null` until [isReady] becomes true.
  (Float32List, bool)? consume() {
    if (!_ready || _nextSeq == null) return null;
    _totalConsumed++;

    final seq = _nextSeq!;
    _nextSeq = seq + 1;

    final packet = _map.remove(seq);
    if (packet != null) {
      _lastValidFrame = packet.samples;
      return (packet.samples, false);
    }

    // Sequence gap — fade out last valid frame to avoid metallic repeat artifacts.
    _lostPackets++;
    final plc = _lastValidFrame;
    if (plc == null) return (Float32List(_numSamples * _numChannels), true);
    final faded = Float32List(plc.length);
    for (int i = 0; i < plc.length; i++) {
      faded[i] = plc[i] * (1.0 - i / plc.length);
    }
    return (faded, true);
  }

  /// Advance [nextExpectedSeq] to [seq] and evict all older packets.
  ///
  /// Called after async player init to discard the backlog that accumulated
  /// while the audio engine was starting up.
  void syncToSeq(int seq) {
    _map.removeWhere((k, _) => k < seq);
    if (_nextSeq == null || _nextSeq! < seq) _nextSeq = seq;
  }

  /// Reset all state (call when stopping).
  void reset() {
    _map.clear();
    _nextSeq = null;
    _lostPackets = 0;
    _totalConsumed = 0;
    _ready = false;
    _lastValidFrame = null;
  }
}
