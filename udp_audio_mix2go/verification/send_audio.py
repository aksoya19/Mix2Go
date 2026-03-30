"""
Send UDP audio packets in the JUCE Mix2Go protocol format.

Header (26 bytes, little-endian):
  uint32 magic       = 0x4D324730  ("M2G0")
  uint32 sampleRate  = 44100
  uint16 numChannels = 2
  uint32 numSamples
  uint64 timestamp   (microseconds)
  uint32 sequenceNumber

Payload:
  interleaved float32 [L, R, L, R, ...]
"""
import socket, math, struct, time, argparse

MAGIC = 0x4D324730
SAMPLE_RATE = 44100
NUM_CHANNELS = 2

def build_packet(float_samples, seq_num):
    """Wrap interleaved float32 samples in a JUCE header."""
    num_samples = len(float_samples) // NUM_CHANNELS
    timestamp = int(time.time() * 1_000_000)  # µs

    header = struct.pack('<I I H I Q I',
        MAGIC,
        SAMPLE_RATE,
        NUM_CHANNELS,
        num_samples,
        timestamp,
        seq_num,
    )
    payload = struct.pack(f'<{len(float_samples)}f', *float_samples)
    return header + payload


def generate_sine(frequency, duration_sec, amplitude=0.4):
    """Return interleaved [L,R,L,R,...] float list."""
    n = int(SAMPLE_RATE * duration_sec)
    out = []
    for i in range(n):
        t = i / SAMPLE_RATE
        v = amplitude * math.sin(2.0 * math.pi * frequency * t)
        out.append(v)  # L
        out.append(v)  # R
    return out


def main():
    parser = argparse.ArgumentParser(description='Send JUCE-format UDP audio')
    parser.add_argument('--ip',   default='127.0.0.1')
    parser.add_argument('--port', type=int, default=12345)
    args = parser.parse_args()

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    # Samples per packet (per channel). 256 is a typical JUCE block size.
    BLOCK_SIZE = 256
    samples_per_packet = BLOCK_SIZE * NUM_CHANNELS  # interleaved count

    # Pre-generate 2 s beep + 2 s silence
    beep    = generate_sine(440, 2.0)
    silence = [0.0] * (SAMPLE_RATE * 2 * NUM_CHANNELS)

    seq = 0
    print(f"Sending to {args.ip}:{args.port}  (Ctrl-C to stop)")

    try:
        while True:
            for label, data in [("Beep", beep), ("Silence", silence)]:
                print(label)
                off = 0
                while off < len(data):
                    chunk = data[off : off + samples_per_packet]
                    pkt = build_packet(chunk, seq)
                    sock.sendto(pkt, (args.ip, args.port))
                    seq += 1
                    off += samples_per_packet
                    # Sleep to match real-time
                    time.sleep(BLOCK_SIZE / SAMPLE_RATE)
    except KeyboardInterrupt:
        print("Stopped.")
    finally:
        sock.close()


if __name__ == "__main__":
    main()
