import Foundation
import VideoToolbox
import AVFoundation

protocol H265EncoderDelegate: AnyObject {
    func encoder(_ encoder: H265Encoder, didOutputNALUnits nalUnits: [Data], timestamp: CMTime)
    func encoder(_ encoder: H265Encoder, didOutputParameterSets vps: Data?, sps: Data?, pps: Data?)
}

class H265Encoder {
    weak var delegate: H265EncoderDelegate?
    
    private var compressionSession: VTCompressionSession?
    private let encoderQueue = DispatchQueue(label: "h265.encoder.queue")
    
    private var vps: Data?
    private var sps: Data?
    private var pps: Data?
    
    private var width: Int32 = 720
    private var height: Int32 = 1280
    private var fps: Int32 = 30
    private var bitrate: Int32 = 3_000_000
    private var keyFrameInterval: Int32 = 30
    
    private var frameCount: Int64 = 0
    private var lastParameterSetTime: Date = Date()
    
    init() {}
    
    func configure(width: Int32, height: Int32, fps: Int32, bitrate: Int32) {
        self.width = width
        self.height = height
        self.fps = fps
        self.bitrate = bitrate
        self.keyFrameInterval = fps * 2
        
        setupCompressionSession()
    }
    
    private func setupCompressionSession() {
        let status = VTCompressionSessionCreate(
            allocator: kCFAllocatorDefault,
            width: width,
            height: height,
            codecType: kCMVideoCodecType_HEVC,
            encoderSpecification: nil,
            imageBufferAttributes: nil,
            compressedDataAllocator: nil,
            outputCallback: compressionOutputCallback,
            refcon: Unmanaged.passUnretained(self).toOpaque(),
            compressionSessionOut: &compressionSession
        )
        
        guard status == noErr, let session = compressionSession else {
            print("Failed to create compression session: \(status)")
            return
        }
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: kVTProfileLevel_HEVC_Main_AutoLevel)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanFalse)
        
        // Increase bitrate for better quality
        let actualBitrate = max(bitrate, 8_000_000) // Minimum 8 Mbps for 720p
        let bitrateLimits = [actualBitrate * 150 / 100, actualBitrate] as CFArray
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_DataRateLimits, value: bitrateLimits)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: actualBitrate as CFNumber)
        
        // Quality settings for reduced block noise
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_Quality, value: 0.9 as CFNumber)
        
        // Additional quality improvements
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MoreFramesBeforeStart, value: 0 as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MoreFramesAfterEnd, value: 0 as CFNumber)
        
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ExpectedFrameRate, value: fps as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval, value: keyFrameInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameIntervalDuration, value: 2.0 as CFNumber)
        
        print("H265Encoder configured: \(width)x\(height) @ \(fps)fps, bitrate: \(actualBitrate)")
        
        VTCompressionSessionPrepareToEncodeFrames(session)
    }
    
    func encode(sampleBuffer: CMSampleBuffer) {
        guard let compressionSession = compressionSession,
              let imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            print("Failed to get image buffer or compression session")
            return
        }
        
        print("Encoding frame #\(frameCount)")
        
        let presentationTimeStamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        
        var flags: VTEncodeInfoFlags = []
        let shouldForceKeyFrame = (frameCount % Int64(keyFrameInterval)) == 0
        
        var properties: CFDictionary?
        if shouldForceKeyFrame {
            let forceKeyFrameDict = [kVTEncodeFrameOptionKey_ForceKeyFrame: kCFBooleanTrue] as CFDictionary
            properties = forceKeyFrameDict
        }
        
        let status = VTCompressionSessionEncodeFrame(
            compressionSession,
            imageBuffer: imageBuffer,
            presentationTimeStamp: presentationTimeStamp,
            duration: duration,
            frameProperties: properties,
            sourceFrameRefcon: nil,
            infoFlagsOut: &flags
        )
        
        if status != noErr {
            print("Encode error: \(status)")
            if status == -12903 { // kVTInvalidSessionErr
                print("Compression session invalid, attempting to recreate...")
                setupCompressionSession()
            }
        } else {
            print("Frame \(frameCount) sent to encoder")
        }
        
        frameCount += 1
        
        let now = Date()
        if now.timeIntervalSince(lastParameterSetTime) >= 1.0 {
            if let vps = vps, let sps = sps, let pps = pps {
                delegate?.encoder(self, didOutputParameterSets: vps, sps: sps, pps: pps)
                lastParameterSetTime = now
            }
        }
    }
    
    private let compressionOutputCallback: VTCompressionOutputCallback = { (outputCallbackRefCon, sourceFrameRefCon, status, infoFlags, sampleBuffer) in
        guard let outputCallbackRefCon = outputCallbackRefCon,
              status == noErr,
              let sampleBuffer = sampleBuffer else {
            return
        }
        
        let encoder = Unmanaged<H265Encoder>.fromOpaque(outputCallbackRefCon).takeUnretainedValue()
        encoder.handleEncodedFrame(sampleBuffer: sampleBuffer)
    }
    
    private func handleEncodedFrame(sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true) as? [[String: Any]],
              let dataBuffer = CMSampleBufferGetDataBuffer(sampleBuffer) else {
            return
        }
        
        var nalUnits: [Data] = []
        let isKeyFrame = attachments.first?[kCMSampleAttachmentKey_NotSync as String] == nil
        
        var bufferData: UnsafeMutablePointer<Int8>?
        var size: Int = 0
        CMBlockBufferGetDataPointer(dataBuffer, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: &size, dataPointerOut: &bufferData)
        
        guard let data = bufferData else { return }
        
        if isKeyFrame {
            if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer) {
                extractParameterSets(from: formatDescription)
                
                if let vps = vps, let sps = sps, let pps = pps {
                    nalUnits.append(vps)
                    nalUnits.append(sps)
                    nalUnits.append(pps)
                    delegate?.encoder(self, didOutputParameterSets: vps, sps: sps, pps: pps)
                }
            }
        }
        
        var offset = 0
        while offset < size - 4 {
            // Read NAL length safely without alignment issues
            var nalLength: UInt32 = 0
            memcpy(&nalLength, data.advanced(by: offset), 4)
            nalLength = nalLength.bigEndian
            let nalLengthInt = Int(nalLength)
            
            offset += 4
            
            if offset + nalLengthInt > size {
                break
            }
            
            var nalUnit = Data()
            nalUnit.append(0x00)
            nalUnit.append(0x00)
            nalUnit.append(0x00)
            nalUnit.append(0x01)
            nalUnit.append(Data(bytes: data.advanced(by: offset), count: nalLengthInt))
            
            nalUnits.append(nalUnit)
            offset += nalLengthInt
        }
        
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        
        print("Encoded frame with \(nalUnits.count) NAL units")
        
        encoderQueue.async { [weak self] in
            guard let self = self else { return }
            print("Calling delegate with \(nalUnits.count) NAL units")
            self.delegate?.encoder(self, didOutputNALUnits: nalUnits, timestamp: timestamp)
        }
    }
    
    private func extractParameterSets(from formatDescription: CMFormatDescription) {
        var parameterSetCount: Int = 0
        var parameterSetPointer: UnsafePointer<UInt8>?
        var parameterSetSize: Int = 0
        var nalUnitHeaderLength: Int32 = 0
        
        var status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 0,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        
        if status == noErr, let pointer = parameterSetPointer {
            var vpsData = Data()
            vpsData.append(0x00)
            vpsData.append(0x00)
            vpsData.append(0x00)
            vpsData.append(0x01)
            vpsData.append(Data(bytes: pointer, count: parameterSetSize))
            self.vps = vpsData
        }
        
        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 1,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        
        if status == noErr, let pointer = parameterSetPointer {
            var spsData = Data()
            spsData.append(0x00)
            spsData.append(0x00)
            spsData.append(0x00)
            spsData.append(0x01)
            spsData.append(Data(bytes: pointer, count: parameterSetSize))
            self.sps = spsData
        }
        
        status = CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
            formatDescription,
            parameterSetIndex: 2,
            parameterSetPointerOut: &parameterSetPointer,
            parameterSetSizeOut: &parameterSetSize,
            parameterSetCountOut: &parameterSetCount,
            nalUnitHeaderLengthOut: &nalUnitHeaderLength
        )
        
        if status == noErr, let pointer = parameterSetPointer {
            var ppsData = Data()
            ppsData.append(0x00)
            ppsData.append(0x00)
            ppsData.append(0x00)
            ppsData.append(0x01)
            ppsData.append(Data(bytes: pointer, count: parameterSetSize))
            self.pps = ppsData
        }
    }
    
    func stop() {
        if let session = compressionSession {
            VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
            VTCompressionSessionInvalidate(session)
            compressionSession = nil
        }
    }
    
    deinit {
        stop()
    }
}