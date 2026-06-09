import 'dart:async';
import 'package:flutter/material.dart';
import '../audio/audio_manager.dart';
import '../audio/audio_buffer.dart';
import 'theme.dart';
import 'widgets/mix2go_icon_painter.dart';
import 'widgets/status_orb.dart';
import 'widgets/vu_meter.dart';
import 'widgets/toggle_row.dart';

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  final AudioManager _manager = AudioManager();

  AudioState _state = AudioState.stopped;
  Timer? _statsTimer;
  StreamSubscription? _stateSub, _vuSub;

  // Network
  int _listenPort = 0;
  String _deviceIP = '';

  // Diagnostics
  int _latency = 0;
  double _lossRate = 0;
  double _bitrate = 0;
  int _decoded = 0;
  String _opusError = '';
  int _underruns = 0;
  bool _rebuffering = false;

  // VU — driven via a ValueNotifier so only the meter repaints (not the whole
  // page) when levels change; full-page setState here would starve the audio.
  final ValueNotifier<List<double>> _vu = ValueNotifier(const [0.0, 0.0]);

  // Panel toggles
  bool _showMetrics = true;
  bool _showNetwork = false;

  @override
  void initState() {
    super.initState();
    _stateSub = _manager.stateStream.listen((s) {
      if (!mounted) return;
      setState(() {
        _state = s;
        if (s == AudioState.stopped || s == AudioState.error) {
          _stopStatsTimer();
        } else {
          _startStatsTimer();
        }
      });
    });
    _vuSub = _manager.vuStream.listen((lv) {
      // No setState — just push to the notifier so only the meter rebuilds.
      _vu.value = lv;
    });
    _manager.logStream.listen((log) => debugPrint('AudioLog: $log'));
  }

  @override
  void dispose() {
    _stopStatsTimer();
    _stateSub?.cancel();
    _vuSub?.cancel();
    _vu.dispose();
    _manager.dispose();
    super.dispose();
  }

  void _startStatsTimer() {
    _statsTimer ??= Timer.periodic(const Duration(milliseconds: 250), (_) {
      if (!mounted) return;
      setState(() {
        _listenPort = _manager.listenPort;
        _deviceIP = _manager.deviceIP;
        _latency = _manager.estimatedLatencyMs;
        _lossRate = _manager.lossRate;
        _bitrate = _manager.bitrateKbps;
        _decoded = _manager.validPacketsDecoded;
        _opusError = _manager.lastOpusError;
        _underruns = _manager.underruns;
        _rebuffering = _manager.isRebuffering;
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
      await _manager.start();
    }
  }

  // ── State-dependent copy ───────────────────────────────────────────────
  String get _headline => switch (_state) {
        AudioState.stopped   => 'Ready to monitor',
        AudioState.buffering => 'Pre-buffering…',
        AudioState.playing   => 'Receiving audio',
        AudioState.error     => 'Connection lost',
      };

  String get _subtitle => switch (_state) {
        AudioState.stopped =>
          'Tap to start receiving audio from your DAW',
        AudioState.buffering => 'Building jitter buffer before playback',
        AudioState.playing =>
          _deviceIP.isNotEmpty ? 'Studio · $_deviceIP' : 'Streaming live',
        AudioState.error => _opusError.isNotEmpty
            ? 'Check DAW plugin — ${_opusError.length > 40 ? '${_opusError.substring(0, 40)}…' : _opusError}'
            : 'Check the DAW plugin and network',
      };

  String get _stateLabel => switch (_state) {
        AudioState.stopped   => 'Stopped',
        AudioState.buffering => 'Buffering',
        AudioState.playing   => 'Streaming',
        AudioState.error     => 'Error',
      };

  @override
  Widget build(BuildContext context) {
    final playing = _state == AudioState.playing;

    return Scaffold(
      backgroundColor: Mix2GoTheme.bg,
      appBar: _appBar(),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 28),
          child: Column(
            children: [
              const SizedBox(height: 12),
              RepaintBoundary(
                child: StatusOrb(
                  state: _state,
                  buffered: _decoded,
                  targetBuffer: ReorderBuffer.kPreBufferPackets,
                ),
              ),
              const SizedBox(height: 22),
              Text(
                _headline,
                style: const TextStyle(
                  fontFamily: Mix2GoTheme.displayFont,
                  fontWeight: FontWeight.w700,
                  fontSize: 26,
                  letterSpacing: 0.5,
                  color: Mix2GoTheme.textPrim,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 13, color: Mix2GoTheme.textMuted),
              ),
              const SizedBox(height: 26),
              _mainButton(),
              const SizedBox(height: 20),
              if (playing) ...[
                RepaintBoundary(
                  child: _panel(
                    child: ValueListenableBuilder<List<double>>(
                      valueListenable: _vu,
                      builder: (context, lv, child) =>
                          VuMeter(levelL: lv[0], levelR: lv[1]),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                ToggleRow(
                  icon: Icons.insights_outlined,
                  label: 'Metrics',
                  value: _showMetrics,
                  onTap: () => setState(() => _showMetrics = !_showMetrics),
                ),
                const SizedBox(height: 10),
                ToggleRow(
                  icon: Icons.lan_outlined,
                  label: 'Network info',
                  value: _showNetwork,
                  onTap: () => setState(() => _showNetwork = !_showNetwork),
                ),
                if (_showMetrics) ...[
                  const SizedBox(height: 14),
                  _metricsPanel(),
                ],
                if (_showNetwork) ...[
                  const SizedBox(height: 14),
                  _networkPanel(),
                ],
              ],
            ],
          ),
        ),
      ),
    );
  }

  // ── App bar ─────────────────────────────────────────────────────────────
  PreferredSizeWidget _appBar() {
    final color = Mix2GoTheme.stateColor(_state);
    return AppBar(
      backgroundColor: Mix2GoTheme.surface1,
      elevation: 0,
      titleSpacing: 16,
      title: Row(
        children: [
          const SizedBox(
            width: 26,
            height: 26,
            child: CustomPaint(painter: Mix2GoIconPainter(drawBackground: false)),
          ),
          const SizedBox(width: 10),
          _wordmark(),
        ],
      ),
      actions: [
        Container(
          margin: const EdgeInsets.only(right: 16),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
          decoration: BoxDecoration(
            color: Mix2GoTheme.surface2,
            borderRadius: BorderRadius.circular(99),
            border: Border.all(color: Mix2GoTheme.borderNorm),
          ),
          child: Row(children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(shape: BoxShape.circle, color: color),
            ),
            const SizedBox(width: 7),
            Text(_stateLabel,
                style: TextStyle(
                    fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ]),
        ),
      ],
    );
  }

  Widget _wordmark() {
    const style = TextStyle(
      fontFamily: Mix2GoTheme.displayFont,
      fontWeight: FontWeight.w700,
      fontSize: 20,
      letterSpacing: 3,
      color: Colors.white,
      height: 1,
    );
    return Row(children: [
      const Text('MIX', style: style),
      ShaderMask(
        shaderCallback: (b) => Mix2GoTheme.accentGradient.createShader(b),
        child: const Text('2', style: style),
      ),
      const Text('GO', style: style),
    ]);
  }

  // ── Main button ─────────────────────────────────────────────────────────
  Widget _mainButton() {
    final active = _state != AudioState.stopped && _state != AudioState.error;
    final label = active
        ? 'Stop'
        : (_state == AudioState.error ? 'Retry' : 'Start receiving');

    return SizedBox(
      width: double.infinity,
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: active ? null : Mix2GoTheme.accentGradient,
          color: active ? Mix2GoTheme.surface2 : null,
          borderRadius: BorderRadius.circular(14),
          border: active ? Border.all(color: Mix2GoTheme.borderNorm) : null,
        ),
        child: ElevatedButton(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.transparent,
            shadowColor: Colors.transparent,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          onPressed: _toggleStart,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: active ? Mix2GoTheme.textMuted : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  // ── Panels ──────────────────────────────────────────────────────────────
  Widget _panel({required Widget child}) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Mix2GoTheme.surface1,
          border: Border.all(color: Mix2GoTheme.borderDim),
          borderRadius: BorderRadius.circular(14),
        ),
        child: child,
      );

  Color _latencyColor(int ms) => ms < 150
      ? Mix2GoTheme.stateStreaming
      : (ms < 250 ? Mix2GoTheme.stateBuffering : Mix2GoTheme.stateError);
  Color _lossColor(double r) => r < 0.05
      ? Mix2GoTheme.stateStreaming
      : (r < 0.15 ? Mix2GoTheme.stateBuffering : Mix2GoTheme.stateError);

  Widget _metricsPanel() {
    return _panel(
      child: Column(children: [
        _diagRow('Latency', '$_latency ms',
            color: _latencyColor(_latency),
            badge: _rebuffering ? 'REBUFFERING' : null),
        _diagRow('Packet loss', '${(_lossRate * 100).toStringAsFixed(1)} %',
            color: _lossColor(_lossRate)),
        _diagRow('Bitrate', '${_bitrate.toStringAsFixed(0)} kbps'),
        _diagRow('Underruns', '$_underruns',
            color: _underruns == 0
                ? Mix2GoTheme.stateStreaming
                : Mix2GoTheme.stateSearching,
            last: _opusError.isEmpty),
        if (_opusError.isNotEmpty)
          _diagRow('Opus error', _opusError,
              color: Mix2GoTheme.stateError, last: true),
      ]),
    );
  }

  Widget _diagRow(String k, String v,
      {Color? color, String? badge, bool last = false}) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 11),
      decoration: BoxDecoration(
        border: last
            ? null
            : const Border(
                bottom: BorderSide(color: Mix2GoTheme.borderDim, width: 1)),
      ),
      child: Row(
        children: [
          Text(k,
              style: const TextStyle(fontSize: 11, color: Mix2GoTheme.textMuted)),
          const Spacer(),
          if (badge != null) ...[
            Container(
              margin: const EdgeInsets.only(right: 8),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Mix2GoTheme.stateSearching.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Mix2GoTheme.stateSearching),
              ),
              child: Text(badge,
                  style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.bold,
                      color: Mix2GoTheme.stateSearching)),
            ),
          ],
          Flexible(
            child: Text(
              v,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                fontWeight: FontWeight.w500,
                color: color ?? Mix2GoTheme.textPrim,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _networkPanel() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
      decoration: BoxDecoration(
        color: Mix2GoTheme.surface1,
        border: Border.all(color: Mix2GoTheme.borderDim),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('IP ADDRESS', style: Mix2GoTheme.eyebrow),
            const SizedBox(height: 4),
            Text(_deviceIP.isNotEmpty ? _deviceIP : '—',
                style: Mix2GoTheme.mono.copyWith(fontSize: 15)),
          ]),
          Container(width: 1, height: 38, color: Mix2GoTheme.borderNorm),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text('UDP PORT', style: Mix2GoTheme.eyebrow),
            const SizedBox(height: 2),
            ShaderMask(
              shaderCallback: (b) =>
                  Mix2GoTheme.accentGradient.createShader(b),
              child: Text(
                _listenPort > 0 ? '$_listenPort' : '—',
                style: const TextStyle(
                  fontFamily: Mix2GoTheme.displayFont,
                  fontWeight: FontWeight.w700,
                  fontSize: 28,
                  letterSpacing: 3,
                  color: Colors.white,
                  height: 1,
                ),
              ),
            ),
          ]),
        ],
      ),
    );
  }
}
