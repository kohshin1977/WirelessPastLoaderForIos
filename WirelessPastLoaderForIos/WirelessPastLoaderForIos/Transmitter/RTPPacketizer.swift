import Foundation

class RTPPacketizer {
    private let maxPayloadSize = 1200
    private var sequenceNumber: UInt16 = 0
    private var timestamp: UInt32 = 0
    private let ssrc: UInt32 = UInt32.random(in: 0..<UInt32.max)
    private let payloadType: UInt8 = 98
    private let clockRate: UInt32 = 90000
    
    enum NALUnitType: UInt8 {
        case VPS = 32
        case SPS = 33
        case PPS = 34
        case IDR_W_RADL = 19
        case IDR_N_LP = 20
        case TRAIL_R = 1
        case TRAIL_N = 0
        case FU = 49
    }
    
    func packetizeNALUnit(_ nalUnit: Data, timestamp: UInt32, isLastNALInFrame: Bool) -> [Data] {
        var packets: [Data] = []
        
        if nalUnit.count <= maxPayloadSize {
            let packet = createSingleNALUnitPacket(nalUnit, timestamp: timestamp, marker: isLastNALInFrame)
            packets.append(packet)
        } else {
            packets = createFragmentationUnits(nalUnit, timestamp: timestamp, isLastNALInFrame: isLastNALInFrame)
        }
        
        return packets
    }
    
    private func createSingleNALUnitPacket(_ nalUnit: Data, timestamp: UInt32, marker: Bool) -> Data {
        var packet = Data()
        
        let rtpHeader = createRTPHeader(marker: marker, timestamp: timestamp)
        packet.append(rtpHeader)
        packet.append(nalUnit)
        
        sequenceNumber = sequenceNumber &+ 1
        
        return packet
    }
    
    private func createFragmentationUnits(_ nalUnit: Data, timestamp: UInt32, isLastNALInFrame: Bool) -> [Data] {
        var packets: [Data] = []
        
        guard nalUnit.count >= 2 else { return packets }
        
        let nalHeader = nalUnit[0..<2]
        let nalHeaderValue = UInt16(nalHeader[0]) << 8 | UInt16(nalHeader[1])
        
        let fuType: UInt8 = NALUnitType.FU.rawValue
        let layerId = (nalHeader[0] & 0x01) << 5 | (nalHeader[1] & 0xF8) >> 3
        let tid = nalHeader[1] & 0x07
        
        let fuHeader1 = (fuType << 1) | (nalHeader[0] & 0x81)
        let fuHeader2 = (layerId << 3) | tid
        
        let nalDataWithoutHeader = nalUnit[2...]
        let nalType = (nalHeaderValue >> 9) & 0x3F
        
        var offset = 0
        let payloadData = nalDataWithoutHeader
        
        while offset < payloadData.count {
            let isStart = (offset == 0)
            let remainingBytes = payloadData.count - offset
            let fragmentSize = min(remainingBytes, maxPayloadSize - 3)
            let isEnd = (offset + fragmentSize >= payloadData.count)
            
            var packet = Data()
            
            let isLastPacket = isEnd && isLastNALInFrame
            let rtpHeader = createRTPHeader(marker: isLastPacket, timestamp: timestamp)
            packet.append(rtpHeader)
            
            packet.append(fuHeader1)
            packet.append(fuHeader2)
            
            var fuIndicator: UInt8 = UInt8(nalType & 0x3F)
            if isStart {
                fuIndicator |= 0x80
            }
            if isEnd {
                fuIndicator |= 0x40
            }
            packet.append(fuIndicator)
            
            let fragmentData = payloadData[payloadData.startIndex.advanced(by: offset)..<payloadData.startIndex.advanced(by: offset + fragmentSize)]
            packet.append(fragmentData)
            
            packets.append(packet)
            sequenceNumber = sequenceNumber &+ 1
            offset += fragmentSize
        }
        
        return packets
    }
    
    private func createRTPHeader(marker: Bool, timestamp: UInt32) -> Data {
        var header = Data(count: 12)
        
        header[0] = 0x80
        header[1] = marker ? (0x80 | payloadType) : payloadType
        
        header[2] = UInt8((sequenceNumber >> 8) & 0xFF)
        header[3] = UInt8(sequenceNumber & 0xFF)
        
        header[4] = UInt8((timestamp >> 24) & 0xFF)
        header[5] = UInt8((timestamp >> 16) & 0xFF)
        header[6] = UInt8((timestamp >> 8) & 0xFF)
        header[7] = UInt8(timestamp & 0xFF)
        
        header[8] = UInt8((ssrc >> 24) & 0xFF)
        header[9] = UInt8((ssrc >> 16) & 0xFF)
        header[10] = UInt8((ssrc >> 8) & 0xFF)
        header[11] = UInt8(ssrc & 0xFF)
        
        return header
    }
    
    func updateTimestamp(frameRate: Int) {
        let ticksPerFrame = clockRate / UInt32(frameRate)
        timestamp = timestamp &+ ticksPerFrame
    }
    
    func resetSequenceNumber() {
        sequenceNumber = 0
    }
}