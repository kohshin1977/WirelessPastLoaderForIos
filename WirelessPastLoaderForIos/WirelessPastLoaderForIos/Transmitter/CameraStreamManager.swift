import AVFoundation
import UIKit
import Combine

class CameraStreamManager: NSObject, ObservableObject {
    private let captureSession = AVCaptureSession()
    private var videoOutput: AVCaptureVideoDataOutput?
    private let videoQueue = DispatchQueue(label: "video.capture.queue")
    
    private let encoder = H265Encoder()
    private let rtpPacketizer = RTPPacketizer()
    private let udpSender = UDPSender()
    
    private var isStreaming = false
    private var currentTimestamp: UInt32 = 0
    private let frameRate = 30
    
    lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let layer = AVCaptureVideoPreviewLayer(session: captureSession)
        layer.videoGravity = .resizeAspectFill
        return layer
    }()
    
    override init() {
        super.init()
        setupCamera()
        encoder.delegate = self
        startPreview()
    }
    
    private func setupCamera() {
        captureSession.beginConfiguration()
        
        captureSession.sessionPreset = .hd1280x720
        
        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back) else {
            print("No camera available")
            return
        }
        
        do {
            let input = try AVCaptureDeviceInput(device: camera)
            if captureSession.canAddInput(input) {
                captureSession.addInput(input)
            }
            
            try camera.lockForConfiguration()
            camera.activeVideoMinFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            camera.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: CMTimeScale(frameRate))
            camera.unlockForConfiguration()
            
        } catch {
            print("Camera setup error: \(error)")
            return
        }
        
        let videoOutput = AVCaptureVideoDataOutput()
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        ]
        videoOutput.setSampleBufferDelegate(self, queue: videoQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        
        if captureSession.canAddOutput(videoOutput) {
            captureSession.addOutput(videoOutput)
        }
        
        self.videoOutput = videoOutput
        
        captureSession.commitConfiguration()
    }
    
    private func startPreview() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession.startRunning()
        }
    }
    
    func startStreaming(host: String, port: UInt16 = 5004) {
        guard !isStreaming else { return }
        
        encoder.configure(width: 720, height: 1280, fps: Int32(frameRate), bitrate: 12_000_000)
        
        udpSender.connect(host: host, port: port)
        
        // Wait a moment for UDP connection to establish
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            // Ensure capture session is running (it should already be running for preview)
            if let session = self?.captureSession, !session.isRunning {
                DispatchQueue.global(qos: .userInitiated).async {
                    session.startRunning()
                }
            }
            self?.isStreaming = true
            print("Streaming started")
        }
        
        print("Streaming started to \(host):\(port)")
    }
    
    func stopStreaming() {
        guard isStreaming else { return }
        
        // Don't stop the capture session to keep preview running
        encoder.stop()
        udpSender.disconnect()
        isStreaming = false
        
        print("Streaming stopped")
    }
    
    private func sendParameterSets(_ vps: Data, sps: Data, pps: Data) {
        let nalUnits = [vps, sps, pps]
        var packets: [Data] = []
        
        for (index, nalUnit) in nalUnits.enumerated() {
            let nalData = nalUnit.dropFirst(4)
            let isLast = (index == nalUnits.count - 1)
            let nalPackets = rtpPacketizer.packetizeNALUnit(Data(nalData), timestamp: currentTimestamp, isLastNALInFrame: isLast)
            packets.append(contentsOf: nalPackets)
        }
        
        udpSender.sendBatch(packets)
    }
}

extension CameraStreamManager: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard isStreaming else { return }
        
        connection.videoOrientation = .portrait
        
        encoder.encode(sampleBuffer: sampleBuffer)
    }
}

extension CameraStreamManager: H265EncoderDelegate {
    func encoder(_ encoder: H265Encoder, didOutputNALUnits nalUnits: [Data], timestamp: CMTime) {
        print("CameraStreamManager received \(nalUnits.count) NAL units")
        
        let timestampValue = UInt32(CMTimeGetSeconds(timestamp) * 90000)
        currentTimestamp = timestampValue
        
        var packets: [Data] = []
        
        for (index, nalUnit) in nalUnits.enumerated() {
            let isLast = (index == nalUnits.count - 1)
            
            let nalData = nalUnit.dropFirst(4)
            let nalPackets = rtpPacketizer.packetizeNALUnit(Data(nalData), timestamp: timestampValue, isLastNALInFrame: isLast)
            packets.append(contentsOf: nalPackets)
        }
        
        print("Created \(packets.count) RTP packets from NAL units")
        udpSender.sendBatch(packets)
        
        rtpPacketizer.updateTimestamp(frameRate: frameRate)
    }
    
    func encoder(_ encoder: H265Encoder, didOutputParameterSets vps: Data?, sps: Data?, pps: Data?) {
        guard let vps = vps, let sps = sps, let pps = pps else { return }
        sendParameterSets(vps, sps: sps, pps: pps)
    }
}