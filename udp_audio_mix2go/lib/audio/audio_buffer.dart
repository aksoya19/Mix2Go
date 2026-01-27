import 'dart:collection';
import 'dart:typed_data';

class AudioBuffer {
  final Queue<Uint8List> _queue = Queue();
  final int maxPackets = 50; 
  final int preBufferThreshold = 10; // Start playing only after we have this many packets

  void add(Uint8List data) {
    if (_queue.length >= maxPackets) {
      _queue.removeFirst();  // Löscht das letzte Packet, wenns voll ist (overflow protection)
    }
    _queue.addLast(data);
  }

  Uint8List? next() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }

  void clear() {
    _queue.clear();
  }

  bool get isReadyToPlay => _queue.length >= preBufferThreshold;
  bool get hasData => _queue.isNotEmpty;
  int get length => _queue.length;
}
