import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';

// ── WinMM structures ─────────────────────────────────────────────────────────

@Packed(1)
final class WAVEFORMATEX extends Struct {
  @Uint16() external int wFormatTag;
  @Uint16() external int nChannels;
  @Uint32() external int nSamplesPerSec;
  @Uint32() external int nAvgBytesPerSec;
  @Uint16() external int nBlockAlign;
  @Uint16() external int wBitsPerSample;
  @Uint16() external int cbSize;
}

@Packed(1)
final class WAVEHDR extends Struct {
  external Pointer<Int8> lpData;
  @Uint32() external int dwBufferLength;
  @Uint32() external int dwBytesRecorded;
  @IntPtr()  external int dwUser;
  @Uint32() external int dwFlags;
  @Uint32() external int dwLoops;
  external Pointer<WAVEHDR> lpNext;
  @IntPtr()  external int reserved;
}

// ── Constants ─────────────────────────────────────────────────────────────────

const int _WAVE_FORMAT_PCM  = 1;
const int _WAVE_MAPPER      = 0xFFFFFFFF; // UINT(-1)
const int _CALLBACK_NULL    = 0;
const int _MMSYSERR_NOERROR = 0;
const int _WHDR_DONE        = 0x00000001;

// ── FFI bindings ──────────────────────────────────────────────────────────────

final _winmm = DynamicLibrary.open('winmm.dll');

final _waveOutOpen = _winmm.lookupFunction<
    Int32 Function(Pointer<IntPtr>, Uint32, Pointer<WAVEFORMATEX>, IntPtr, IntPtr, Uint32),
    int  Function(Pointer<IntPtr>, int,    Pointer<WAVEFORMATEX>, int,   int,   int)
>('waveOutOpen');

final _waveOutPrepareHeader = _winmm.lookupFunction<
    Int32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int  Function(int,    Pointer<WAVEHDR>, int)
>('waveOutPrepareHeader');

final _waveOutUnprepareHeader = _winmm.lookupFunction<
    Int32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int  Function(int,    Pointer<WAVEHDR>, int)
>('waveOutUnprepareHeader');

final _waveOutWrite = _winmm.lookupFunction<
    Int32 Function(IntPtr, Pointer<WAVEHDR>, Uint32),
    int  Function(int,    Pointer<WAVEHDR>, int)
>('waveOutWrite');

final _waveOutReset = _winmm.lookupFunction<
    Int32 Function(IntPtr),
    int  Function(int)
>('waveOutReset');

final _waveOutClose = _winmm.lookupFunction<
    Int32 Function(IntPtr),
    int  Function(int)
>('waveOutClose');

// ── WindowsAudioOutput ────────────────────────────────────────────────────────
//
// Double-buffer ring using WinMM waveOut.
//
// kNumBuffers × 20ms = 160ms of pre-buffer. A 5ms poll timer refills any
// buffer that the hardware has marked WHDR_DONE. This keeps the audio ring
// full without using a Dart Timer to drive the sample-rate — the hardware
// clock drives playback, the timer only tops up the queue.

class WindowsAudioOutput {
  static const int _kNumBuffers    = 8;   // 8 × 20ms = 160ms headroom
  static const int _kSamplesPerBuf = 960; // one Opus frame per buffer slot
  static const int _kChannels      = 2;
  static const int _kBytesPerBuf   = _kSamplesPerBuf * _kChannels * 2; // Int16

  int  _hWaveOut = 0;
  bool _isOpen   = false;

  final _headers = <Pointer<WAVEHDR>>[];
  final _pcmBufs = <Pointer<Int8>>[];

  void Function(int)? onFeedSamples;
  Timer? _pollTimer;

  bool get isOpen => _isOpen;

  Future<void> setup({required int sampleRate, required int channelCount}) async {
    if (_isOpen) await release();

    final hwoPtr = calloc<IntPtr>();
    final fmtPtr = calloc<WAVEFORMATEX>();
    try {
      final f = fmtPtr.ref;
      f.wFormatTag      = _WAVE_FORMAT_PCM;
      f.nChannels       = channelCount;
      f.nSamplesPerSec  = sampleRate;
      f.wBitsPerSample  = 16;
      f.nBlockAlign     = channelCount * 2;
      f.nAvgBytesPerSec = sampleRate * channelCount * 2;
      f.cbSize          = 0;

      final r = _waveOutOpen(hwoPtr, _WAVE_MAPPER, fmtPtr, 0, 0, _CALLBACK_NULL);
      if (r != _MMSYSERR_NOERROR) {
        throw Exception('[WinAudio] waveOutOpen failed: MMRESULT=$r');
      }
      _hWaveOut = hwoPtr.value;

      for (int i = 0; i < _kNumBuffers; i++) {
        final buf = calloc<Int8>(_kBytesPerBuf);
        final hdr = calloc<WAVEHDR>();
        hdr.ref.lpData         = buf;
        hdr.ref.dwBufferLength = _kBytesPerBuf;
        hdr.ref.dwFlags        = _WHDR_DONE; // mark done so first poll fills them
        _waveOutPrepareHeader(_hWaveOut, hdr, sizeOf<WAVEHDR>());
        _pcmBufs.add(buf);
        _headers.add(hdr);
      }
      _isOpen = true;
      print('[WinAudio] waveOut opened: ${sampleRate}Hz ${channelCount}ch Int16');
    } finally {
      calloc.free(hwoPtr);
      calloc.free(fmtPtr);
    }
  }

  void setFeedCallback(void Function(int) cb) {
    onFeedSamples = cb;
  }

  void start() {
    if (!_isOpen) return;
    _pollTimer?.cancel();
    // Poll every 5ms — fills any WHDR_DONE buffers from the decode pipeline.
    _pollTimer = Timer.periodic(const Duration(milliseconds: 5), (_) => _poll());
  }

  void _poll() {
    if (!_isOpen) return;
    for (int i = 0; i < _headers.length; i++) {
      if (_headers[i].ref.dwFlags & _WHDR_DONE != 0) {
        onFeedSamples?.call(0);
      }
    }
  }

  // Called from AudioManager._onFeedNeeded after it assembles one Opus frame.
  void feed(Int16List samples) {
    if (!_isOpen) return;
    for (int i = 0; i < _headers.length; i++) {
      final hdr = _headers[i];
      if (hdr.ref.dwFlags & _WHDR_DONE != 0) {
        // Copy PCM bytes into native buffer
        final native = _pcmBufs[i].cast<Uint8>().asTypedList(_kBytesPerBuf);
        final src    = samples.buffer.asUint8List(
            samples.offsetInBytes,
            samples.lengthInBytes.clamp(0, _kBytesPerBuf));
        native.setRange(0, src.length, src);
        if (src.length < _kBytesPerBuf) native.fillRange(src.length, _kBytesPerBuf, 0);

        hdr.ref.dwFlags &= ~_WHDR_DONE; // clear before write
        _waveOutWrite(_hWaveOut, hdr, sizeOf<WAVEHDR>());
        return; // one buffer filled per call
      }
    }
    // All 8 buffers busy (160ms queued) — rare, drop silently
  }

  Future<void> release() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    if (!_isOpen) return;

    _waveOutReset(_hWaveOut); // marks all pending headers WHDR_DONE synchronously
    for (int i = 0; i < _headers.length; i++) {
      _waveOutUnprepareHeader(_hWaveOut, _headers[i], sizeOf<WAVEHDR>());
      calloc.free(_headers[i]);
      calloc.free(_pcmBufs[i]);
    }
    _headers.clear();
    _pcmBufs.clear();
    _waveOutClose(_hWaveOut);
    _hWaveOut = 0;
    _isOpen   = false;
    print('[WinAudio] waveOut closed');
  }
}
