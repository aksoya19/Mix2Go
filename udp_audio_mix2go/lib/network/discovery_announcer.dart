import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Periodically broadcasts this device's audio listening port so the Mix2Go
/// VST plugin can discover the app automatically — no manual IP/port entry.
///
/// ── Protocol ──────────────────────────────────────────────────────────────
///   ASCII payload sent as raw bytes:  `MIX2GO:2:<audioPort>`
///   e.g.                              `MIX2GO:2:43210`
///
///   Destination: 255.255.255.255:[kDiscoveryPort]  (UDP limited broadcast)
///   Interval:    every [kIntervalMs] ms
///
/// The VST plugin listens on [kDiscoveryPort].  On receipt it reads the
/// sender's IP from the datagram source address and [audioPort] from the
/// payload, then auto-starts streaming to that endpoint.
/// ─────────────────────────────────────────────────────────────────────────
class DiscoveryAnnouncer {
  /// The VST plugin listens on this port for discovery broadcasts.
  /// Obscure enough that port collisions are extremely unlikely.
  static const int kDiscoveryPort = 40051;

  /// How often to broadcast (ms).
  static const int kIntervalMs = 1000;

  RawDatagramSocket? _socket;
  Timer?             _timer;
  int                _audioPort = 0;

  bool get isRunning => _timer != null;

  // ── Public API ───────────────────────────────────────────────────────────

  /// Open a broadcast socket and start sending [audioPort] every second.
  Future<void> start(int audioPort) async {
    if (isRunning) return;
    _audioPort = audioPort;
    try {
      _socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4, 0,
        reuseAddress: true,
        reusePort:    false,
      );
      _socket!.broadcastEnabled = true;
      _send();
      _timer = Timer.periodic(
        const Duration(milliseconds: kIntervalMs), (_) => _send());
      debugPrint('[Discovery] Broadcasting audioPort=$_audioPort'
                 ' → 255.255.255.255:$kDiscoveryPort every ${kIntervalMs}ms');
    } catch (e) {
      debugPrint('[Discovery] Could not open broadcast socket: $e');
    }
  }

  /// Stop broadcasting and release the socket.
  void stop() {
    _timer?.cancel();
    _timer = null;
    _socket?.close();
    _socket = null;
    debugPrint('[Discovery] Stopped');
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  void _send() {
    if (_socket == null) return;
    final bytes = Uint8List.fromList('MIX2GO:2:$_audioPort'.codeUnits);
    try {
      _socket!.send(
        bytes, InternetAddress('255.255.255.255'), kDiscoveryPort);
    } catch (_) {}
  }
}
