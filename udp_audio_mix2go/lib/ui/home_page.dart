import 'dart:async';
import 'package:flutter/material.dart';
import '../audio/audio_player.dart';
import '../audio/audio_source.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final player = AudioPlayerEngine();
  final source = AudioSource();

  Timer? timer;
  bool running = false;

  @override
  void initState() {
    super.initState();
    player.init();
  }

  void start() {
    running = true;

    timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      if (!running) return;
      final packet = source.getNextPacket();
      player.play(packet);
    });

    setState(() {});
  }

  void stop() {
    running = false;
    timer?.cancel();
    setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mix2Go – Audio Test")),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              running ? "Testton läuft" : "Gestoppt",
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
