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
  int    _buffered     = 0;
  double _lossRate     = 0;
  double _bitrate      = 0;
  int    _rawReceived  = 0;  // raw UDP datagrams (before magic check)
  int    _decoded      = 0;  // successfully Opus-decoded frames
  String _headerInfo   = ''; // header fields from last packet
  String _opusError    = ''; // last Opus decode error

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
            _startStatsTimer(); // also poll during buffering for diagnostics
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
        _buffered    = _manager.buffered;
        _lossRate    = _manager.lossRate;
        _bitrate     = _manager.bitrateKbps;
        _rawReceived = _manager.rawDatagramsReceived;
        _decoded     = _manager.validPacketsDecoded;
        _headerInfo  = _manager.lastHeaderInfo;
        _opusError   = _manager.lastOpusError;

        // During buffering: update status to show network diagnostic counts.
        if (_state == AudioState.buffering) {
          if (_rawReceived == 0) {
            _statusMsg = 'Warte auf UDP-Pakete… (Port ${_portCtrl.text})';
          } else if (_decoded == 0) {
            // Show header info so we can diagnose the Opus failure
            _statusMsg = _headerInfo.isNotEmpty
                ? 'Opus-Fehler! $_headerInfo'
                : 'Pakete empfangen ($_rawReceived) — Opus-Fehler!';
          } else {
            _statusMsg = 'Pufferung… $_decoded/${ReorderBuffer.kPreBufferPackets} '
                         'Pakete ($_rawReceived roh)';
          }
        }
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
                    buffered:    _buffered,
                    maxBuffer:   ReorderBuffer.kMaxPackets,
                    lossRate:    _lossRate,
                    bitrate:     _bitrate,
                    rawReceived: _rawReceived,
                    decoded:     _decoded,
                    opusError:   _opusError,
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
    required this.rawReceived,
    required this.decoded,
    required this.opusError,
  });

  final int    buffered;
  final int    maxBuffer;
  final double lossRate;
  final double bitrate;
  final int    rawReceived;
  final int    decoded;
  final String opusError;

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
          const SizedBox(height: 12),

          // Network diagnostic row: raw UDP vs decoded Opus
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('UDP roh / dekodiert',
                  style: TextStyle(color: Colors.white60, fontSize: 13)),
              Text(
                '$rawReceived / $decoded',
                style: TextStyle(
                  color: rawReceived == 0
                      ? Colors.red        // nothing arrived at all
                      : decoded == 0
                          ? Colors.orange // arrived but Opus decode failed
                          : Colors.green, // all good
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),

          // Show Opus error if present
          if (opusError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              opusError,
              style: const TextStyle(
                color: Colors.orange,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
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
