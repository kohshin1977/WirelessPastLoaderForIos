#!/usr/bin/env python3
"""
H.265 RTP Stream Receiver and Decoder
Receives H.265 video stream via RTP/UDP and displays it in real-time
"""

import socket
import struct
import threading
import queue
import time
import numpy as np
import cv2
import av
from io import BytesIO
import argparse
import sys

class RTPPacket:
    def __init__(self, data):
        self.data = data
        self.parse()
    
    def parse(self):
        if len(self.data) < 12:
            raise ValueError("Invalid RTP packet size")
        
        # Parse RTP header
        byte0 = self.data[0]
        self.version = (byte0 >> 6) & 0x03
        self.padding = (byte0 >> 5) & 0x01
        self.extension = (byte0 >> 4) & 0x01
        self.cc = byte0 & 0x0F
        
        byte1 = self.data[1]
        self.marker = (byte1 >> 7) & 0x01
        self.payload_type = byte1 & 0x7F
        
        self.sequence = struct.unpack('!H', self.data[2:4])[0]
        self.timestamp = struct.unpack('!I', self.data[4:8])[0]
        self.ssrc = struct.unpack('!I', self.data[8:12])[0]
        
        # Calculate payload offset
        self.header_size = 12 + (self.cc * 4)
        if self.extension:
            ext_header_start = self.header_size
            if ext_header_start + 4 <= len(self.data):
                ext_length = struct.unpack('!H', self.data[ext_header_start+2:ext_header_start+4])[0]
                self.header_size += 4 + (ext_length * 4)
        
        self.payload = self.data[self.header_size:]

class H265RTPDepacketizer:
    def __init__(self):
        # key: (ssrc, timestamp, start_seq)
        self.fragments = {}
        self.fragment_timeout = 0.5  # 500ms timeout for fragments
        
    def process_packet(self, packet):
        if len(packet.payload) < 2:
            return None
        
        # Parse H.265 NAL unit header
        nal_header = struct.unpack('!H', packet.payload[0:2])[0]
        nal_type = (nal_header >> 9) & 0x3F
        
        if nal_type == 49:  # Fragmentation Unit (FU)
            return self.handle_fu(packet)
        elif nal_type == 48:  # Aggregation Packet (AP)
            return self.handle_ap(packet)
        else:  # Single NAL unit
            return self.handle_single_nal(packet)
    
    def handle_single_nal(self, packet):
        # Single NAL unit packet
        return b'\x00\x00\x00\x01' + packet.payload
    
    def handle_fu(self, packet):
        if len(packet.payload) < 3:
            return None
        
        # Parse FU header
        fu_header = packet.payload[2]
        start_bit = (fu_header >> 7) & 0x01
        end_bit = (fu_header >> 6) & 0x01
        fu_type = fu_header & 0x3F
        
        # Reconstruct NAL header
        nal_header = struct.unpack('!H', packet.payload[0:2])[0]
        nal_header = (nal_header & 0x81FF) | (fu_type << 9)
        
        if start_bit:
            # Start of fragmented NAL unit - use composite key
            key = (packet.ssrc, packet.timestamp, packet.sequence)
            self.fragments[key] = {
                'data': struct.pack('!H', nal_header) + packet.payload[3:],
                'last_seq': packet.sequence,
                'timestamp': time.time()
            }
            return None
        
        # Find matching fragment for continuation/end
        candidates = [(k, v) for k, v in self.fragments.items()
                      if k[0] == packet.ssrc and k[1] == packet.timestamp]
        
        if not candidates:
            return None
        
        # Get the fragment with closest sequence number
        key, state = min(candidates, key=lambda kv: abs(packet.sequence - kv[1]['last_seq'] - 1))
        
        state['data'] += packet.payload[3:]
        state['last_seq'] = packet.sequence
        state['timestamp'] = time.time()
        
        if end_bit:
            # End of fragmented NAL unit
            nal_data = state['data']
            del self.fragments[key]
            return b'\x00\x00\x00\x01' + nal_data
        
        return None
    
    def cleanup_old_fragments(self):
        """Remove fragments that have timed out"""
        current_time = time.time()
        keys_to_delete = [
            k for k, v in self.fragments.items()
            if current_time - v['timestamp'] > self.fragment_timeout
        ]
        for key in keys_to_delete:
            del self.fragments[key]
    
    def handle_ap(self, packet):
        # Aggregation packet - contains multiple NAL units
        nalus = []
        offset = 2  # Skip NAL header
        
        while offset < len(packet.payload):
            if offset + 2 > len(packet.payload):
                break
            
            nal_size = struct.unpack('!H', packet.payload[offset:offset+2])[0]
            offset += 2
            
            if offset + nal_size > len(packet.payload):
                break
            
            nal_data = packet.payload[offset:offset+nal_size]
            nalus.append(b'\x00\x00\x00\x01' + nal_data)
            offset += nal_size
        
        return b''.join(nalus) if nalus else None

class H265Decoder:
    def __init__(self):
        self.codec = av.CodecContext.create('hevc', 'r')
        self.frame_buffer = b''
        self.sps_received = False
        self.pps_received = False
        self.vps_received = False
        
    def decode_nal_unit(self, nal_data, marker=False):
        if not nal_data:
            return []
        
        # Accumulate NAL units
        self.frame_buffer += nal_data
        
        # Check NAL unit type
        if len(nal_data) > 5:
            nal_type = (nal_data[4] >> 1) & 0x3F
            
            # VPS (32), SPS (33), PPS (34)
            if nal_type == 32:
                self.vps_received = True
            elif nal_type == 33:
                self.sps_received = True
            elif nal_type == 34:
                self.pps_received = True
        
        frames = []
        # Decode when marker indicates access unit boundary
        if marker and self.frame_buffer:
            try:
                packet = av.Packet(self.frame_buffer)
                for frame in self.codec.decode(packet):
                    frames.append(frame.to_ndarray(format='bgr24'))
            except Exception as e:
                print(f"Decode error: {e}")
            finally:
                # Clear buffer regardless of success to prevent accumulation
                self.frame_buffer = b''
        
        return frames
    

class H265StreamReceiver:
    def __init__(self, port=5004):
        self.port = port
        self.socket = None
        self.running = False
        self.packet_queue = queue.Queue(maxsize=1000)
        self.frame_queue = queue.Queue(maxsize=30)  # Queue for decoded frames
        self.depacketizer = H265RTPDepacketizer()
        self.decoder = H265Decoder()
        self.stats_lock = threading.Lock()
        self.stats = {
            'packets_received': 0,
            'bytes_received': 0,
            'frames_decoded': 0,
            'last_sequence': -1,
            'lost_packets': 0
        }
        self.last_cleanup_time = time.time()
        
    def start(self):
        # Create UDP socket
        self.socket = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        # Increase receive buffer for high bitrate streams
        self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4*1024*1024)
        self.socket.bind(('0.0.0.0', self.port))
        self.socket.settimeout(0.1)
        
        self.running = True
        
        # Start receiver thread
        receiver_thread = threading.Thread(target=self.receive_packets)
        receiver_thread.daemon = True
        receiver_thread.start()
        
        # Start processor thread
        processor_thread = threading.Thread(target=self.process_packets)
        processor_thread.daemon = True
        processor_thread.start()
        
        print(f"Receiver started on port {self.port}")
        print("Waiting for H.265 stream...")
        print("Press 'q' to quit, 's' for statistics")
        
        # Display loop
        self.display_stream()
    
    def receive_packets(self):
        while self.running:
            try:
                data, addr = self.socket.recvfrom(65535)
                
                with self.stats_lock:
                    self.stats['packets_received'] += 1
                    self.stats['bytes_received'] += len(data)
                
                try:
                    packet = RTPPacket(data)
                    
                    # Check for packet loss (more tolerant of reordering)
                    if self.stats['last_sequence'] != -1:
                        expected = (self.stats['last_sequence'] + 1) & 0xFFFF
                        if packet.sequence != expected:
                            # Calculate difference accounting for wraparound
                            diff = (packet.sequence - expected) & 0xFFFF
                            # Only count as loss if significantly ahead (not reordering)
                            if diff > 0 and diff < 100:  # Forward jump within reasonable range
                                with self.stats_lock:
                                    self.stats['lost_packets'] += diff
                            elif diff > 0xFFF0:  # Small backward jump - likely reordering
                                pass  # Don't count as loss
                    
                    with self.stats_lock:
                        self.stats['last_sequence'] = packet.sequence
                    
                    if not self.packet_queue.full():
                        self.packet_queue.put(packet)
                    
                except Exception as e:
                    print(f"Packet parse error: {e}")
                    
            except socket.timeout:
                continue
            except Exception as e:
                if self.running:
                    print(f"Receive error: {e}")
    
    def process_packets(self):
        while self.running:
            try:
                packet = self.packet_queue.get(timeout=0.1)
                
                # Cleanup old fragments periodically
                current_time = time.time()
                if current_time - self.last_cleanup_time > 0.5:
                    self.depacketizer.cleanup_old_fragments()
                    self.last_cleanup_time = current_time
                
                # Depacketize RTP to NAL units
                nal_data = self.depacketizer.process_packet(packet)
                
                if nal_data:
                    # Try to decode with marker bit
                    frames = self.decoder.decode_nal_unit(nal_data, marker=packet.marker)
                    
                    # Handle all returned frames
                    for frame in frames:
                        with self.stats_lock:
                            self.stats['frames_decoded'] += 1
                        
                        # Queue frame for display in main thread
                        if not self.frame_queue.full():
                            self.frame_queue.put(frame)
                        
            except queue.Empty:
                continue
            except Exception as e:
                print(f"Process error: {e}")
    
    def display_stream(self):
        cv2.namedWindow('H.265 Stream', cv2.WINDOW_NORMAL)
        last_stats_time = time.time()
        
        while self.running:
            # Display frames from queue (main thread)
            try:
                frame = self.frame_queue.get_nowait()
                cv2.imshow('H.265 Stream', frame)
            except queue.Empty:
                pass
            
            key = cv2.waitKey(1) & 0xFF
            
            if key == ord('q'):
                self.running = False
                break
            elif key == ord('s'):
                self.print_statistics()
            
            # Auto print stats every 5 seconds
            if time.time() - last_stats_time > 5:
                self.print_statistics()
                last_stats_time = time.time()
        
        cv2.destroyAllWindows()
        if self.socket:
            self.socket.close()
    
    def print_statistics(self):
        with self.stats_lock:
            print("\n--- Statistics ---")
            print(f"Packets received: {self.stats['packets_received']}")
            print(f"Bytes received: {self.stats['bytes_received']:,}")
            print(f"Frames decoded: {self.stats['frames_decoded']}")
            print(f"Lost packets: {self.stats['lost_packets']}")
            if self.stats['packets_received'] > 0:
                loss_rate = (self.stats['lost_packets'] / 
                           (self.stats['packets_received'] + self.stats['lost_packets'])) * 100
                print(f"Packet loss rate: {loss_rate:.2f}%")
            print("-----------------\n")

def main():
    parser = argparse.ArgumentParser(description='H.265 RTP Stream Receiver')
    parser.add_argument('-p', '--port', type=int, default=5004,
                       help='UDP port to listen on (default: 5004)')
    
    args = parser.parse_args()
    
    try:
        receiver = H265StreamReceiver(port=args.port)
        receiver.start()
    except KeyboardInterrupt:
        print("\nShutting down...")
    except Exception as e:
        print(f"Error: {e}")
        sys.exit(1)

if __name__ == '__main__':
    main()