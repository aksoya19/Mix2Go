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
  static const int kPreBufferPackets = 5;

  /// Hard cap on buffered packets — oldest is evicted on overflow.
  static const int kMaxPackets = 60;

  final SplayTreeMap<int, JucePacket> _map = SplayTreeMap();

  int? _nextSeq;
  int _lostPackets = 0;
  int _totalConsumed = 0;
  bool _ready = false;

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

  /// Packets currently held in the buffer.
  int get buffered => _map.length;

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
    if (packet != null) return (packet.samples, false);

    // Sequence gap — substitute a silent frame of the correct size.
    _lostPackets++;
    return (Float32List(_numSamples * _numChannels), true);
  }

  /// Reset all state (call when stopping).
  void reset() {
    _map.clear();
    _nextSeq = null;
    _lostPackets = 0;
    _totalConsumed = 0;
    _ready = false;
  }
}
