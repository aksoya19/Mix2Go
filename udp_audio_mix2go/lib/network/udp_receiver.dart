import 'dart:typed_data';
import 'package:udp/udp.dart';

class UdpReceiver {
  static const int port = 5000;
  UDP? _socket;

  Future<void> start(void Function(Uint8List) onPacket) async {
    _socket = await UDP.bind(Endpoint.any(port: Port(port)));

    _socket!.asStream().listen((datagram) {
      if (datagram != null) {
        onPacket(datagram.data);
      }
    });
  }

  void stop() {
    _socket?.close();
  }
}
