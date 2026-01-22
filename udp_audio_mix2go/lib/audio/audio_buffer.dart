import 'dart:collection';
import 'dart:typed_data';

class AudioBuffer {
  final Queue<Uint8List> _queue = Queue();
  final int maxPackets = 50;

  void add(Uint8List data) {
    if (_queue.length >= maxPackets) {
      _queue.removeFirst();
    }
    _queue.addLast(data);
  }

  Uint8List? next() {
    if (_queue.isEmpty) return null;
    return _queue.removeFirst();
  }
}
