import 'dart:collection';
import 'dart:typed_data';

/// Sequence-ordered jitter buffer for decoded Opus frames (Int16 interleaved PCM).
///
/// Frames are keyed by their UDP sequence number and consumed in strict order.
/// A gap in the sequence signals FEC so the caller can request Opus packet-loss
/// concealment instead of silence.
///
/// Thread safety: all methods must be called from the same Dart isolate.
class ReorderBuffer {
  /// Packets to accumulate before [consume] is allowed to return real data.
  /// 4 × 20 ms = 80 ms of pre-roll / jitter absorption.
  /// Must be > kFramesPerFeed (2) + look-ahead (1) = 3, so the first
  /// onFeedNeeded call can drain 3 frames without hitting a gap.
  static const int kPreBufferPackets = 4;

  /// Hard cap on buffered packets — oldest evicted when exceeded.
  /// 150 × 10 ms = 1.5 s maximum buffer depth.
  static const int kMaxPackets = 150;

  final SplayTreeMap<int, Int16List> _map = SplayTreeMap();

  int?  _nextSeq;
  int   _lostPackets   = 0;
  int   _totalConsumed = 0;
  bool  _ready         = false;
  bool  _eosMarked     = false;
  bool  _eosConfirmed  = false;

  // ── Enqueueing ──────────────────────────────────────────────────────────────

  /// Enqueue a decoded [samples] frame for [sequenceNumber].
  ///
  /// [numSamples] and [numChannels] are informational only (used for stream
  /// restart detection sizing).
  void add(int sequenceNumber, Int16List samples,
           int numSamples, int numChannels) {
    // Stream restart: seq jumped far behind current read head → hard reset.
    if (_ready && _nextSeq != null &&
        sequenceNumber < _nextSeq! - kMaxPackets) {
      _map.clear();
      _nextSeq       = sequenceNumber;
      _lostPackets   = 0;
      _totalConsumed = 0;
      _ready         = false;
    }

    // Evict oldest packet on overflow; advance read head past it so
    // consume() never loops through a cascade of stale gaps.
    if (_map.length >= kMaxPackets) {
      final evicted = _map.firstKey()!;
      _map.remove(evicted);
      if (_nextSeq != null && _nextSeq! <= evicted) {
        _nextSeq = _map.isEmpty ? evicted + 1 : _map.firstKey();
      }
    }

    _map[sequenceNumber] = samples;
    _nextSeq ??= sequenceNumber;

    if (!_ready && _map.length >= kPreBufferPackets) _ready = true;
  }

  // ── State ───────────────────────────────────────────────────────────────────

  /// True once [kPreBufferPackets] have arrived.
  bool get isReady => _ready;

  /// Packets currently held.
  int get buffered => _map.length;

  /// Fraction of consumed slots that were gaps (packet loss rate, 0.0–1.0).
  double get lossRate =>
      _totalConsumed == 0 ? 0.0 : _lostPackets / _totalConsumed;

  // ── EOS ─────────────────────────────────────────────────────────────────────

  /// Mark end-of-stream.  Confirmed immediately if the buffer is already empty.
  void markEos() {
    _eosMarked = true;
    if (_map.isEmpty) _eosConfirmed = true;
  }

  /// True once EOS is marked and the last buffered frame has been consumed.
  bool get isEosConfirmed => _eosConfirmed;

  // ── Consuming ───────────────────────────────────────────────────────────────

  /// Consume the next frame in sequence order.
  ///
  /// Returns `(frame, false)` — real audio; use it.
  /// Returns `(null,  true)`  — sequence gap; apply Opus FEC.
  /// Returns `(null,  false)` — pre-buffer not yet full; feed silence.
  (Int16List?, bool) consume() {
    if (!_ready || _nextSeq == null) return (null, false);

    _totalConsumed++;
    final seq = _nextSeq!;
    _nextSeq = seq + 1;

    final frame = _map.remove(seq);
    if (frame != null) {
      if (_eosMarked && _map.isEmpty) _eosConfirmed = true;
      return (frame, false);
    }

    _lostPackets++;
    return (null, true); // gap → request FEC
  }

  // ── Latency management ──────────────────────────────────────────────────────

  /// Discard accumulated backlog, keeping only the newest [keepPackets] frames.
  ///
  /// Call this before the first [consume] so playback starts at real-time
  /// rather than replaying the setup-time accumulation.
  void seekToLatest([int keepPackets = kPreBufferPackets]) {
    while (_map.length > keepPackets) {
      _map.remove(_map.firstKey());
    }
    if (_map.isNotEmpty) _nextSeq = _map.firstKey();
  }

  // ── Reset ───────────────────────────────────────────────────────────────────

  /// Reset all state (call on stream stop).
  void reset() {
    _map.clear();
    _nextSeq       = null;
    _lostPackets   = 0;
    _totalConsumed = 0;
    _ready         = false;
    _eosMarked     = false;
    _eosConfirmed  = false;
  }
}
