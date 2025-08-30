import Foundation
import Network

class UDPSender {
    private var connection: NWConnection?
    private let queue = DispatchQueue(label: "udp.sender.queue")
    private var isConnected = false
    
    init() {}
    
    func connect(host: String, port: UInt16) {
        let hostEndpoint = NWEndpoint.Host(host)
        let portEndpoint = NWEndpoint.Port(rawValue: port)!
        
        connection = NWConnection(host: hostEndpoint, port: portEndpoint, using: .udp)
        
        connection?.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                print("UDP connection ready")
                self?.isConnected = true
            case .failed(let error):
                print("UDP connection failed: \(error)")
                self?.isConnected = false
            case .cancelled:
                print("UDP connection cancelled")
                self?.isConnected = false
            default:
                break
            }
        }
        
        connection?.start(queue: queue)
    }
    
    func send(_ data: Data) {
        guard isConnected else {
            print("UDP not connected, dropping packet")
            return
        }
        
        connection?.send(content: data, completion: .contentProcessed { error in
            if let error = error {
                print("UDP send error: \(error)")
            } else {
                // Debug: Successfully sent packet
                print("Sent packet: \(data.count) bytes")
            }
        })
    }
    
    func sendBatch(_ packets: [Data]) {
        print("Sending batch of \(packets.count) packets")
        for packet in packets {
            send(packet)
        }
    }
    
    func disconnect() {
        connection?.cancel()
        connection = nil
        isConnected = false
    }
    
    deinit {
        disconnect()
    }
}