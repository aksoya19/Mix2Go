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
///   Sends to TWO addresses every interval:
///     1. 255.255.255.255       (limited broadcast  — works on most LANs)
///     2. `<subnet>.255`        (directed broadcast — gets through routers
///                               that block 255.255.255.255, computed from
///                               the device's own IP assuming a /24 subnet)
///   Interval: every [kIntervalMs] ms
/// ─────────────────────────────────────────────────────────────────────────
// TODO: remove after presentation — proper fix would be mDNS/Bonjour
const bool _kEnableHotspotWorkaround = true;

class DiscoveryAnnouncer {
  static const int kDiscoveryPort = 40051;
  static const int kIntervalMs    = 1000;

  RawDatagramSocket? _socket;
  Timer?             _timer;
  int                _audioPort   = 0;
  List<String>       _addresses   = const [];

  bool get isRunning => _timer != null;

  // ── Public API ───────────────────────────────────────────────────────────

  Future<void> start(int audioPort) async {
    if (isRunning) return;
    _audioPort = audioPort;

    _addresses = await _collectAddresses();
    debugPrint('[Discovery] targets: $_addresses');

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
      debugPrint('[Discovery] Broadcasting port=$_audioPort'
                 ' every ${kIntervalMs}ms');
    } catch (e) {
      debugPrint('[Discovery] Could not open broadcast socket: $e');
    }
  }

  void stop() {
    _timer?.cancel(); _timer = null;
    _socket?.close(); _socket = null;
    debugPrint('[Discovery] Stopped');
  }

  // ── Internal ─────────────────────────────────────────────────────────────

  void _send() {
    if (_socket == null) return;
    final bytes = List<int>.from('MIX2GO:2:$_audioPort'.codeUnits);
    for (final addr in _addresses) {
      _sendTo(addr, bytes);
    }
  }

  void _sendTo(String address, List<int> bytes) {
    try {
      _socket!.send(
        bytes, InternetAddress(address), kDiscoveryPort);
    } catch (_) {}
  }

  /// Collects all addresses to send discovery broadcasts to:
  /// - 255.255.255.255 (limited broadcast)
  /// - <subnet>.255 per interface (directed broadcast, covers ZeroTier etc.)
  /// - Hotspot workaround: when this device is the iPhone hotspot AP at
  ///   172.20.10.1, iOS routes broadcast out cellular (wrong interface).
  ///   Unicast to each possible client IP (172.20.10.2–14) is routed via
  ///   the hotspot bridge instead and reaches the Mac correctly.
  static Future<List<String>> _collectAddresses() async {
    final seen = <String>{};
    seen.add('255.255.255.255');

    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          debugPrint('[Discovery] ${iface.name}: ${addr.address}');
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;

          final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          seen.add(bcast);

          // Hotspot workaround
          if (_kEnableHotspotWorkaround && addr.address == '172.20.10.1') {
            for (int i = 2; i <= 14; i++) {
              seen.add('172.20.10.$i');
            }
            debugPrint('[Discovery] Hotspot mode — added unicast scan 172.20.10.2-14');
          }
        }
      }
    } catch (e) {
      debugPrint('[Discovery] Interface enumeration failed: $e');
    }

    return seen.toList();
  }
}
