#!/usr/bin/env python3
"""
Extract H.265 Elementary Stream from RTP packets in PCAP file
"""

import struct
import sys
from scapy.all import *
import argparse

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
        self.fragments = {}
        self.packets = []
        
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
            # Start of fragmented NAL unit
            self.fragments[packet.timestamp] = struct.pack('!H', nal_header) + packet.payload[3:]
        elif packet.timestamp in self.fragments:
            # Continuation of fragmented NAL unit
            self.fragments[packet.timestamp] += packet.payload[3:]
            
            if end_bit:
                # End of fragmented NAL unit
                nal_data = self.fragments.pop(packet.timestamp)
                return b'\x00\x00\x00\x01' + nal_data
        
        return None
    
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

def extract_h265_stream(pcap_file, output_file, port=5004):
    """Extract H.265 elementary stream from PCAP file"""
    
    print(f"Reading PCAP file: {pcap_file}")
    
    try:
        packets = rdpcap(pcap_file)
    except Exception as e:
        print(f"Error reading PCAP file: {e}")
        return False
    
    depacketizer = H265RTPDepacketizer()
    nal_units = []
    packet_count = 0
    rtp_packet_count = 0
    
    print(f"Processing {len(packets)} packets...")
    
    for pkt in packets:
        packet_count += 1
        
        # Filter UDP packets on specified port
        if not (pkt.haslayer(UDP) and (pkt[UDP].dport == port or pkt[UDP].sport == port)):
            continue
        
        try:
            # Extract UDP payload (RTP data)
            rtp_data = bytes(pkt[UDP].payload)
            
            if len(rtp_data) < 12:
                continue
            
            rtp_packet = RTPPacket(rtp_data)
            rtp_packet_count += 1
            
            # Process RTP packet to extract NAL units
            nal_data = depacketizer.process_packet(rtp_packet)
            
            if nal_data:
                nal_units.append(nal_data)
                
                # Print NAL unit info
                if len(nal_data) >= 6:
                    nal_type = (nal_data[5] >> 1) & 0x3F
                    nal_names = {
                        32: "VPS", 33: "SPS", 34: "PPS",
                        19: "IDR_W_RADL", 20: "IDR_N_LP", 21: "CRA_NUT",
                        1: "TRAIL_R", 0: "TRAIL_N"
                    }
                    nal_name = nal_names.get(nal_type, f"Type_{nal_type}")
                    print(f"NAL Unit: {nal_name} ({nal_type}), Size: {len(nal_data)} bytes, Timestamp: {rtp_packet.timestamp}")
                
        except Exception as e:
            print(f"Error processing packet {packet_count}: {e}")
            continue
    
    print(f"\nProcessed {packet_count} total packets, {rtp_packet_count} RTP packets")
    print(f"Extracted {len(nal_units)} NAL units")
    
    if not nal_units:
        print("No H.265 NAL units found!")
        return False
    
    # Write elementary stream to file
    total_size = 0
    with open(output_file, 'wb') as f:
        for nal in nal_units:
            f.write(nal)
            total_size += len(nal)
    
    print(f"H.265 elementary stream saved to: {output_file}")
    print(f"Total stream size: {total_size:,} bytes")
    
    return True

def main():
    parser = argparse.ArgumentParser(description='Extract H.265 Elementary Stream from PCAP file')
    parser.add_argument('pcap_file', help='Input PCAP file')
    parser.add_argument('-o', '--output', default='stream.h265', help='Output H.265 file (default: stream.h265)')
    parser.add_argument('-p', '--port', type=int, default=5004, help='RTP port number (default: 5004)')
    
    args = parser.parse_args()
    
    if not os.path.exists(args.pcap_file):
        print(f"Error: PCAP file not found: {args.pcap_file}")
        sys.exit(1)
    
    success = extract_h265_stream(args.pcap_file, args.output, args.port)
    
    if success:
        print(f"\nYou can now play the extracted stream with:")
        print(f"ffplay {args.output}")
        print(f"vlc {args.output}")
    else:
        sys.exit(1)

if __name__ == '__main__':
    main()