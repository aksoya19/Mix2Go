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
        value = int(16000.0 * math.sin(2.0 * math.pi * frequency * t))
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

    print(f"Generating audio with beep-pause pattern...")
    
    # 2.0 second beep, 2.0 second silence
    beep_data = generate_sine_wave(duration=2.0, frequency=440)
    silence_data = generate_sine_wave(duration=2.0, frequency=0) # 0 Hz = silence
    
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    packet_size = 1024 # Payload size in bytes (256 samples stereo)

    # Send loop
    try:
        while True:
            # Send Beep
            print("Beep...")
            send_chunk(sock, beep_data, target_ip, target_port, packet_size)
            
            # Send Silence (or just pause sending if we want to simulate network gap, 
            # but for streaming, sending silence is better to keep clock sync if player expects stream)
            # User said "not so many" waves, maybe they mean pause sending. 
            # But continuous stream expects data. Let's send silence.
            print("Silence...")
            send_chunk(sock, silence_data, target_ip, target_port, packet_size)
            
    except KeyboardInterrupt:
        print("Stopped.")
    finally:
        sock.close()

def send_chunk(sock, data, ip, port, packet_size):
    samples_per_packet = packet_size // 4
    packet_duration = samples_per_packet / 44100.0
    
    offset = 0
    while offset < len(data):
        chunk = data[offset:offset+packet_size]
        sock.sendto(chunk, (ip, port))
        offset += packet_size
        time.sleep(packet_duration)

if __name__ == "__main__":
    main()
