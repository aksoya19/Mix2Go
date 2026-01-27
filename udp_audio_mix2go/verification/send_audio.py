import socket
import math
import struct
import time
import argparse

def generate_sine_wave(frequency=440, sample_rate=44100, duration=1.0):
    num_samples = int(sample_rate * duration)
    # Stereo: 2 channels
    data = bytearray()
    for i in range(num_samples):
        t = float(i) / sample_rate
        value = int(32767.0 * math.sin(2.0 * math.pi * frequency * t))
        # Clamp value
        value = max(-32768, min(32767, value))
        # Pack as little-endian 16-bit signed integer, twice for stereo
        packed = struct.pack('<hh', value, value)
        data.extend(packed)
    return data

def main():
    parser = argparse.ArgumentParser(description='Send UDP Audio')
    parser.add_argument('--ip', default='127.0.0.1', help='Target IP')
    parser.add_argument('--port', type=int, default=5000, help='Target Port')
    args = parser.parse_args()

    target_ip = args.ip
    target_port = args.port

    print(f"Generating 10 seconds of 440Hz Sine Wave...")
    audio_data = generate_sine_wave(duration=10.0)
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    
    packet_size = 1024 # Payload size in bytes (256 samples stereo)
    
    print(f"Sending to {target_ip}:{target_port}...")
    
    # Calculate delay per packet to match real-time
    # 1024 bytes = 256 samples (stereo 16-bit = 4 bytes/sample)
    # 256 samples / 44100 Hz = ~0.0058 seconds (5.8 ms)
    samples_per_packet = packet_size // 4
    packet_duration = samples_per_packet / 44100.0
    
    offset = 0
    try:
        while offset < len(audio_data):
            chunk = audio_data[offset:offset+packet_size]
            sock.sendto(chunk, (target_ip, target_port))
            offset += packet_size
            
            # Simple sleep to roughly match timing (it won't be perfect but good enough for testing)
            time.sleep(packet_duration) 
            
            if offset % (packet_size * 100) == 0:
                print(f"Sent {offset} bytes...")
                
        print("Done.")
    except KeyboardInterrupt:
        print("Stopped.")
    finally:
        sock.close()

if __name__ == "__main__":
    main()
