import 'dart:typed_data';
import 'package:udp/udp.dart';

class UdpReceiver {
  UDP? _socket;
  bool _isRunning = false;

  bool get isRunning => _isRunning;

  Future<void> start(
      {required int port, required void Function(Uint8List) onPacket}) async {
    if (_isRunning) return;

    try {
      _socket = await UDP.bind(Endpoint.any(port: Port(port)));
      _isRunning = true;
      print('UDP Receiver started on port $port');

      _socket!.asStream().listen((datagram) {
        if (datagram != null && datagram.data.isNotEmpty) {
          onPacket(datagram.data);
        }
      }, onError: (e) {
        print("UDP Stream Error: $e");
        stop();
      }, onDone: () {
        print("UDP Stream Closed");
        stop();
      });
    } catch (e) {
      _isRunning = false;
      // Rethrow with a more user-friendly message or handle it 
      throw Exception("Konnte Port $port nicht binden. Vielleicht ist er belegt? Details: $e");
    }
  }

  void stop() {
    if (!_isRunning) return;
    _socket?.close();
    _socket = null;
    _isRunning = false;
    print('UDP Receiver stopped');
  }
}

