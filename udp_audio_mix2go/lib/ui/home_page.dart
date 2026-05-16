import 'dart:async';
import 'package:flutter/material.dart';
import '../audio/audio_manager.dart';
import '../audio/audio_buffer.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioManager _manager = AudioManager();
  final TextEditingController _portCtrl = TextEditingController(text: '12345');

  AudioState _state       = AudioState.stopped;
  String     _statusMsg   = 'Bereit';
  Timer?     _statsTimer;

  // Stats shown in UI
  int    _buffered  = 0;
  double _lossRate  = 0;
  double _bitrate   = 0;

  @override
  void initState() {
    super.initState();

    _manager.stateStream.listen((state) {
      if (!mounted) return;
      setState(() {
        _state = state;
        switch (state) {
          case AudioState.stopped:
            _statusMsg = 'Gestoppt';
            _stopStatsTimer();
            break;
          case AudioState.buffering:
            _statusMsg = 'Pufferung… (${ReorderBuffer.kPreBufferPackets} Pakete)';
            break;
          case AudioState.playing:
            _statusMsg = 'Wiedergabe läuft';
            _startStatsTimer();
            break;
          case AudioState.error:
            _statusMsg = 'Fehler';
            _stopStatsTimer();
            break;
        }
      });
    });

    _manager.logStream.listen((log) {
      debugPrint('AudioLog: $log');
    });
  }

  @override
  void dispose() {
    _stopStatsTimer();
    _manager.dispose();
    _portCtrl.dispose();
    super.dispose();
  }

  void _startStatsTimer() {
    _statsTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() {
        _buffered = _manager.buffered;
        _lossRate = _manager.lossRate;
        _bitrate  = _manager.bitrateKbps;
      });
    });
  }

  void _stopStatsTimer() {
    _statsTimer?.cancel();
    _statsTimer = null;
  }

  Future<void> _toggleStart() async {
    if (_state != AudioState.stopped) {
      await _manager.stop();
    } else {
      final port = int.tryParse(_portCtrl.text);
      if (port == null) {
        setState(() => _statusMsg = 'Ungültiger Port');
        return;
      }
      await _manager.start(port);
    }
  }

  // ── Build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final bool active = _state != AudioState.stopped;
    final Color stateColor = switch (_state) {
      AudioState.stopped  => Colors.grey,
      AudioState.buffering => Colors.amber,
      AudioState.playing  => Colors.green,
      AudioState.error    => Colors.red,
    };

    return Scaffold(
      backgroundColor: const Color(0xFF1A1A2E),
      appBar: AppBar(
        backgroundColor: const Color(0xFF16213E),
        title: const Text('Mix2Go',
            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
        centerTitle: true,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 480),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                // State indicator dot + label
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Container(
                      width: 12, height: 12,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle, color: stateColor,
                        boxShadow: [BoxShadow(color: stateColor.withValues(alpha: .5),
                            blurRadius: 6, spreadRadius: 2)],
                      ),
                    ),
                    const SizedBox(width: 10),
                    Text(_statusMsg,
                        style: const TextStyle(
                            fontSize: 16, color: Colors.white70)),
                  ],
                ),

                const SizedBox(height: 32),

                // Port input
                TextField(
                  controller: _portCtrl,
                  enabled: !active,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Colors.white),
                  decoration: InputDecoration(
                    labelText: 'UDP-Port',
                    labelStyle: const TextStyle(color: Colors.white54),
                    border: const OutlineInputBorder(),
                    enabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white24)),
                    disabledBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: Colors.white12)),
                    focusedBorder: OutlineInputBorder(
                        borderSide: BorderSide(color: stateColor)),
                  ),
                ),

                const SizedBox(height: 20),

                // Start / Stop button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: _toggleStart,
                    style: ElevatedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      backgroundColor: active ? Colors.red.shade700 : Colors.blue.shade700,
                      foregroundColor: Colors.white,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8)),
                    ),
                    child: Text(
                      active ? 'Stop' : 'Empfang starten',
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),

                const SizedBox(height: 32),

                // Stats panel (visible when active)
                AnimatedOpacity(
                  opacity: active ? 1.0 : 0.0,
                  duration: const Duration(milliseconds: 300),
                  child: _StatsPanel(
                    buffered:  _buffered,
                    maxBuffer: ReorderBuffer.kMaxPackets,
                    lossRate:  _lossRate,
                    bitrate:   _bitrate,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Stats panel widget ─────────────────────────────────────────────────────────

class _StatsPanel extends StatelessWidget {
  const _StatsPanel({
    required this.buffered,
    required this.maxBuffer,
    required this.lossRate,
    required this.bitrate,
  });

  final int    buffered;
  final int    maxBuffer;
  final double lossRate;
  final double bitrate;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F3460),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Buffer bar
          _StatRow(
            label: 'Puffer',
            value: '$buffered Pakete / ${buffered * 20} ms',
            child: LinearProgressIndicator(
              value: maxBuffer > 0 ? buffered / maxBuffer : 0,
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(
                buffered < 4 ? Colors.red : Colors.green),
            ),
          ),
          const SizedBox(height: 12),

          // Loss rate
          _StatRow(
            label: 'Paketverlust',
            value: '${(lossRate * 100).toStringAsFixed(1)} %',
            child: LinearProgressIndicator(
              value: lossRate.clamp(0.0, 1.0),
              backgroundColor: Colors.white12,
              valueColor: AlwaysStoppedAnimation<Color>(
                lossRate < 0.05 ? Colors.green
                    : lossRate < 0.15 ? Colors.amber : Colors.red),
            ),
          ),
          const SizedBox(height: 12),

          // Bitrate
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Bitrate', style: TextStyle(color: Colors.white60, fontSize: 13)),
              Text('${bitrate.toStringAsFixed(0)} kbps',
                  style: const TextStyle(color: Colors.white, fontSize: 13,
                      fontWeight: FontWeight.w600)),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.label, required this.value, required this.child});
  final String label;
  final String value;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white60, fontSize: 13)),
            Text(value,  style: const TextStyle(color: Colors.white,   fontSize: 13,
                fontWeight: FontWeight.w600)),
          ],
        ),
        const SizedBox(height: 4),
        child,
      ],
    );
  }
}
