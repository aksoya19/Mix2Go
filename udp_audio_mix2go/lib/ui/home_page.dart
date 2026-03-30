import 'dart:async';
import 'package:flutter/material.dart';
import '../audio/audio_manager.dart';

class HomePage extends StatefulWidget {
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioManager _audioManager = AudioManager();
  final TextEditingController _portController = TextEditingController(text: "12345");

  String _statusMessage = "Bereit";
  bool _isRunning = false;

  @override
  void initState() {
    super.initState();
    
    // Listen to state changes
    _audioManager.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        switch (state) {
          case AudioState.stopped:
            _isRunning = false;
            _statusMessage = "Gestoppt";
            break;
          case AudioState.buffering:
             _isRunning = true;
            _statusMessage = "Pufferung...";
            break;
          case AudioState.playing:
             _isRunning = true;
            _statusMessage = "Gibt Audio wieder";
            break;
          case AudioState.error:
             _isRunning = false;
            _statusMessage = "Ein Fehler ist aufgetreten";
            break;
        }
      });
    });

    // Listen to logs for more details (optional, but good for debug)
    _audioManager.logStream.listen((log) {
      print("AudioLog: $log");
      // Optional: Update status with log if it's not just a state change
      if (_audioManager.currentState == AudioState.error) {
         if (mounted) setState(() => _statusMessage = log);
      }
    });
  }

  @override
  void dispose() {
    _audioManager.dispose();
    _portController.dispose();
    super.dispose();
  }

  Future<void> _toggleStart() async {
    if (_isRunning) {
      await _audioManager.stop();
    } else {
      final port = int.tryParse(_portController.text);
      if (port == null) {
        setState(() => _statusMessage = "Ungültiger Port");
        return;
      }
      await _audioManager.start(port);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Mix2Go – Audio Receiver")),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                _statusMessage,
                style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _portController,
                decoration: const InputDecoration(
                  labelText: "Port",
                  border: OutlineInputBorder(),
                ),
                keyboardType: TextInputType.number,
                enabled: !_isRunning,
              ),
              const SizedBox(height: 20),
              ElevatedButton(
                onPressed: _toggleStart,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                  backgroundColor: _isRunning ? Colors.red : Theme.of(context).primaryColor,
                  foregroundColor: Colors.white,
                ),
                child: Text(
                  _isRunning ? "Stop" : "Empfang Starten",
                  style: const TextStyle(fontSize: 18),
                ),
              ),
              const SizedBox(height: 10),
              if (_isRunning)
                const CircularProgressIndicator()
            ],
          ),
        ),
      ),
    );
  }
}
