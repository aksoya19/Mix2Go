import 'dart:async';
import 'package:flutter/material.dart';
import '../network/udp_receiver.dart';
import '../audio/audio_buffer.dart';
import '../audio/audio_player.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final receiver = UdpReceiver();
  final buffer = AudioBuffer();
  final player = AudioPlayerEngine();

  bool running = false;

  @override
  void initState() {
    super.initState();
    player.init();
  }

  void start() async {
    setState(() => running = true);

    await receiver.start((packet) {
      buffer.add(packet);
    });

    Timer.periodic(const Duration(milliseconds: 5), (_) async {
      if (!running) return;
      final data = buffer.next();
      if (data != null) {
        await player.play(data);
      }
    });
  }

  void stop() {
    setState(() => running = false);
    receiver.stop();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mix2Go – Receiver")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              running ? "Empfängt Audio…" : "Nicht verbunden",
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(height: 20),
            ElevatedButton(
              onPressed: running ? stop : start,
              child: Text(running ? "Stop" : "Start"),
            ),
          ],
        ),
      ),
    );
  }
}
