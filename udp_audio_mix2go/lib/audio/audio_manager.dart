import 'dart:async';
import 'dart:collection';
import 'dart:io' show Platform;
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import 'package:flutter_pcm_sound/flutter_pcm_sound.dart';
import 'package:opus_dart/opus_dart.dart';
import '../network/udp_receiver.dart';
import 'audio_buffer.dart';
import 'windows_audio_output.dart';

enum AudioState { stopped, buffering, playing, error }

/// Orchestrates UDP reception → ReorderBuffer → audio output.
///
/// v2 Pull-model pipeline:
///   UDP callback  →  ReorderBuffer.add()           (enqueue decoded Opus frame)
///   onFeedNeeded  →  ReorderBuffer.consume()        (dequeue or Opus FEC)
///                 →  FlutterPcmSound.feed()         (hardware pull — no timer!)
///
/// No Timer.periodic — the audio hardware callback drives consumption rate.
/// This eliminates the timer-drift crackling of the old push model.
class AudioManager {
  final UdpReceiver    _receiver   = UdpReceiver();
  final ReorderBuffer  _buffer     = ReorderBuffer();
  SimpleOpusDecoder?   _opusDecoder;
  WindowsAudioOutput?  _winAudio;

  final StreamController<AudioState> _stateCtrl =
      StreamController<AudioState>.broadcast();
  final StreamController<String> _logCtrl =
      StreamController<String>.broadcast();

  Stream<AudioState> get stateStream => _stateCtrl.stream;
  Stream<String>     get logStream   => _logCtrl.stream;

  bool       _isDisposed   = false;
  AudioState _currentState = AudioState.stopped;
  AudioState get currentState => _currentState;

  // Stream parameters (set from first received packet)
  int _numChannels  = 2;
  int _numSamples   = 960; // per channel
  int _sampleRate   = 48000;

  // Internal queue bridges Opus frame size (960 samples) and hardware block size
  // (variable, e.g. 512 or 256). Prevents partial-frame artifacts.
  final Queue<Int16List> _feedQueue = Queue();

  // EOS fade state
  bool   _fadingOut = false;
  double _fadeGain  = 1.0;
  static const double _kFadeStep = 0.1; // 10 frames × 20 ms = 200 ms fade

  // Stats
  int _underruns    = 0;
  int _totalFedMs   = 0;
  int _bytesReceived = 0;
  DateTime? _startTime;

  // Exposed to UI
  int    get buffered      => _buffer.buffered;
  double get lossRate      => _buffer.lossRate;
  double get bitrateKbps {
    if (_startTime == null) return 0;
    final secs = DateTime.now().difference(_startTime!).inMilliseconds / 1000.0;
    return secs > 0 ? (_bytesReceived * 8) / (secs * 1000) : 0;
  }

  // ── Public API ─────────────────────────────────────────────────────────────

  Future<void> start(int port) async {
    if (_currentState != AudioState.stopped) return;

    _buffer.reset();
    _feedQueue.clear();
    _fadingOut    = false;
    _fadeGain     = 1.0;
    _underruns    = 0;
    _totalFedMs   = 0;
    _bytesReceived = 0;
    _startTime    = null;

    _updateState(AudioState.buffering);
    _log('Listening on UDP port $port…');

    try {
      await _receiver.start(
        port: port,
        onPacket: _handlePacket,
        onEos:    _handleEos,
      );
    } catch (e) {
      _log('Error binding port $port: $e');
      _updateState(AudioState.error);
    }
  }

  Future<void> stop() async {
    _receiver.stop();

    if (Platform.isWindows) {
      try { await _winAudio?.release(); } catch (_) {}
      _winAudio = null;
    } else {
      try { await FlutterPcmSound.release(); } catch (_) {}
    }

    _opusDecoder?.destroy();
    _opusDecoder = null;

    _buffer.reset();
    _feedQueue.clear();
    _fadingOut  = false;
    _fadeGain   = 1.0;

    _updateState(AudioState.stopped);
    _log('Stopped.');
  }

  void dispose() {
    _isDisposed = true;
    stop();
    _stateCtrl.close();
    _logCtrl.close();
  }

  // ── Packet / EOS handlers (UDP callback) ───────────────────────────────────

  void _handlePacket(Mix2GoPacket packet) {
    if (_isDisposed) return;

    _bytesReceived += packet.rawBytes;
    _startTime ??= DateTime.now();

    _numChannels = packet.numChannels;
    _numSamples  = packet.numSamples;
    _sampleRate  = packet.sampleRate;

    _buffer.add(packet.sequenceNumber, packet.samples,
                packet.numSamples, packet.numChannels);

    if (_currentState == AudioState.buffering && _buffer.isReady) {
      _initPlayer();
    }
  }

  void _handleEos(int seq) {
    if (_isDisposed) return;
    _buffer.markEos();
    if (_buffer.isEosConfirmed && !_fadingOut) {
      _fadingOut = true;
      _log('EOS received — fading out…');
    }
  }

  // ── Player initialisation ──────────────────────────────────────────────────

  Future<void> _initPlayer() async {
    try {
      _opusDecoder = SimpleOpusDecoder(
        sampleRate: _sampleRate,
        channels:   _numChannels,
      );

      if (Platform.isWindows) {
        _winAudio = WindowsAudioOutput();
        await _winAudio!.setup(sampleRate: _sampleRate, channelCount: _numChannels);
        _winAudio!.setFeedCallback(_onFeedNeeded);
        _winAudio!.start();
      } else {
        await FlutterPcmSound.setup(
          sampleRate:   _sampleRate,
          channelCount: _numChannels,
        );
        await FlutterPcmSound.setFeedThreshold(_numSamples * _numChannels);
        FlutterPcmSound.setFeedCallback(_onFeedNeeded);
        FlutterPcmSound.start();
      }

      _updateState(AudioState.playing);
      _log('Playback started — sr=$_sampleRate  ch=$_numChannels'
           '  frame=${_numSamples}smpl / 20ms'
           '  pre-buffer=${ReorderBuffer.kPreBufferPackets} pkts'
           '  backend=${Platform.isWindows ? "waveOut" : "flutter_pcm_sound"}');
    } catch (e) {
      _log('Player init failed: $e');
      _updateState(AudioState.error);
    }
  }

  // ── Feed callback (audio hardware pull) ────────────────────────────────────

  // Called by flutter_pcm_sound when the hardware buffer drops below threshold.
  // [remainingSamples] = how many samples remain in the hardware buffer.
  // We must call FlutterPcmSound.feed() before returning.
  void _onFeedNeeded(int remainingSamples) {
    if (_isDisposed) return;

    final needed = _numSamples * _numChannels; // Int16 values per Opus frame

    // Refill internal queue until it holds at least one hardware-block worth
    while (_feedQueue.fold<int>(0, (s, f) => s + f.length) < needed * 2) {
      final dequeued = _dequeueNextFrame();
      if (dequeued == null) break;
      _feedQueue.add(dequeued);
    }

    // Drain exactly `needed` Int16 values for the hardware block
    final out = Int16List(needed);
    int pos = 0;
    while (pos < needed && _feedQueue.isNotEmpty) {
      final chunk = _feedQueue.first;
      final take  = (needed - pos).clamp(0, chunk.length);
      out.setRange(pos, pos + take, chunk);
      _feedQueue.removeFirst();
      if (take < chunk.length) {
        _feedQueue.addFirst(Int16List.sublistView(chunk, take));
      }
      pos += take;
    }

    // Apply EOS fade
    if (_fadingOut) {
      _applyFade(out);
      _fadeGain = (_fadeGain - _kFadeStep).clamp(0.0, 1.0);
      if (_fadeGain <= 0.0) {
        stop(); // fully silent — stop cleanly
        return;
      }
    }

    if (Platform.isWindows) {
      _winAudio?.feed(out); // synchronous waveOut write
    } else {
      FlutterPcmSound.feed(PcmArrayInt16.fromList(out)); // fire-and-forget
    }

    _totalFedMs += 20; // each Opus frame = 20 ms
    if ((_totalFedMs ~/ 1000) > ((_totalFedMs - 20) ~/ 1000)) {
      _log('buf: ${_buffer.buffered} pkts  '
           'loss: ${(_buffer.lossRate * 100).toStringAsFixed(1)}%  '
           'underruns: $_underruns  '
           'bitrate: ${bitrateKbps.toStringAsFixed(0)} kbps');
    }
  }

  // ── Internal helpers ───────────────────────────────────────────────────────

  /// Returns the next decoded frame or null if not yet ready.
  Int16List? _dequeueNextFrame() {
    if (!_buffer.isReady) {
      // Pre-buffering: feed silence to prevent hardware underrun click
      return Int16List(_numSamples * _numChannels);
    }

    final (frame, needsFec) = _buffer.consume();

    if (frame != null) return frame;

    if (needsFec) {
      // Opus FEC: pass null payload → decoder uses redundancy from prior packet.
      // Produces a naturally attenuating concealment frame — no oscillation.
      _underruns++;
      // Only attempt FEC if the decoder has already processed at least one
      // packet (lastPacketDurationMs != null) — otherwise decode(input:null)
      // throws a StateError because it cannot estimate the missing duration.
      final dec = _opusDecoder;
      if (dec != null && dec.lastPacketDurationMs != null) {
        try {
          return dec.decode(input: null);
        } catch (_) {}
      }
      return Int16List(_numSamples * _numChannels);
    }

    // Pre-buffer not full yet
    return Int16List(_numSamples * _numChannels);
  }

  void _applyFade(Int16List buf) {
    for (int i = 0; i < buf.length; i++) {
      buf[i] = (buf[i] * _fadeGain).round().clamp(-32768, 32767);
    }
  }

  void _updateState(AudioState state) {
    if (_currentState == state || _isDisposed) return;
    _currentState = state;
    if (!_stateCtrl.isClosed) _stateCtrl.add(state);
  }

  void _log(String msg) {
    debugPrint('[AudioManager] $msg');
    if (!_logCtrl.isClosed) _logCtrl.add(msg);
  }
}
