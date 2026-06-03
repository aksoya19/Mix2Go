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
class DiscoveryAnnouncer {
  static const int kDiscoveryPort = 40051;
  static const int kIntervalMs    = 1000;

  RawDatagramSocket? _socket;
  Timer?             _timer;
  int                _audioPort = 0;
  String?            _subnetBroadcast; // e.g. "192.168.0.255"

  bool get isRunning => _timer != null;

  // ── Public API ───────────────────────────────────────────────────────────

  Future<void> start(int audioPort) async {
    if (isRunning) return;
    _audioPort = audioPort;

    // Calculate the subnet-directed broadcast address (assumes /24).
    _subnetBroadcast = await _getSubnetBroadcast();
    debugPrint('[Discovery] subnet broadcast: $_subnetBroadcast');

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

    // 1) Limited broadcast — delivered on local segment
    _sendTo('255.255.255.255', bytes);

    // 2) Subnet-directed broadcast — passes through routers that block 255.255.255.255
    //    and often gets through WiFi APs with "client isolation" enabled.
    if (_subnetBroadcast != null && _subnetBroadcast != '255.255.255.255') {
      _sendTo(_subnetBroadcast!, bytes);
    }
  }

  void _sendTo(String address, List<int> bytes) {
    try {
      _socket!.send(
        bytes, InternetAddress(address), kDiscoveryPort);
    } catch (_) {}
  }

  /// Returns the subnet-directed broadcast for the best non-loopback IPv4
  /// interface (assumes /24).  Prefers routable addresses (192.168.x.x /
  /// 10.x.x.x / 172.16-31.x.x) over link-local (169.254.x.x).
  /// Falls back to '255.255.255.255'.
  static Future<String> _getSubnetBroadcast() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );

      // Log all interfaces for debugging.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          debugPrint('[Discovery] Interface ${iface.name}: ${addr.address}');
        }
      }

      // Pass 1: prefer en0 — always WiFi on iOS/macOS.
      for (final iface in interfaces) {
        if (iface.name != 'en0') continue;
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            debugPrint('[Discovery] Selected broadcast (en0): $bcast (${addr.address})');
            return bcast;
          }
        }
      }

      // Pass 2: any routable address (skip link-local 169.254.x.x and 127.x.x.x).
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length != 4) continue;
          final first  = int.tryParse(parts[0]) ?? 0;
          final second = int.tryParse(parts[1]) ?? 0;
          if (first == 169 && second == 254) continue;
          if (first == 127) continue;
          final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
          debugPrint('[Discovery] Selected broadcast (routable): $bcast (${addr.address} on ${iface.name})');
          return bcast;
        }
      }

      // Pass 3: last resort — any non-loopback address.
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final parts = addr.address.split('.');
          if (parts.length == 4) {
            final bcast = '${parts[0]}.${parts[1]}.${parts[2]}.255';
            debugPrint('[Discovery] Fallback broadcast: $bcast');
            return bcast;
          }
        }
      }
    } catch (e) {
      debugPrint('[Discovery] Could not determine subnet broadcast: $e');
    }
    return '255.255.255.255';
  }
}
