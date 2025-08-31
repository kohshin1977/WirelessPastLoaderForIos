//
//  TerminalBDisplayView.swift
//  WirelessPastLoaderForIos
//
//  Created by 徳永功伸 on 2025/08/31.
//

import SwiftUI

struct TerminalBDisplayView: View {
    @State private var port = "5004"
    @State private var isReceiving = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var deviceIPAddress = ""
    @State private var receivedFrames = 0
    @State private var receivedBytes = 0
    
    var body: some View {
        VStack(spacing: 0) {
            // Video display area (placeholder for now)
            ZStack {
                Rectangle()
                    .fill(Color.black)
                    .ignoresSafeArea()
                
                if !isReceiving {
                    VStack(spacing: 20) {
                        Image(systemName: "tv.fill")
                            .font(.system(size: 80))
                            .foregroundColor(.gray)
                        
                        Text("映像待機中")
                            .font(.title2)
                            .foregroundColor(.gray)
                    }
                } else {
                    VStack(spacing: 20) {
                        ProgressView()
                            .progressViewStyle(CircularProgressViewStyle(tint: .white))
                            .scaleEffect(2)
                        
                        Text("受信中...")
                            .font(.title3)
                            .foregroundColor(.white)
                        
                        VStack(alignment: .leading, spacing: 5) {
                            Text("フレーム: \(receivedFrames)")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                            Text("受信データ: \(formatBytes(receivedBytes))")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                        }
                        .padding()
                        .background(Color.black.opacity(0.6))
                        .cornerRadius(10)
                    }
                }
            }
            .overlay(alignment: .top) {
                HStack {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("端末B - ディスプレイ")
                            .font(.headline)
                            .foregroundColor(.white)
                        
                        if !deviceIPAddress.isEmpty {
                            Text("Device IP: \(deviceIPAddress)")
                                .font(.caption)
                                .foregroundColor(.white)
                        }
                        
                        if isReceiving {
                            HStack {
                                Circle()
                                    .fill(Color.green)
                                    .frame(width: 8, height: 8)
                                Text("ポート \(port) で受信中")
                                    .font(.caption)
                                    .foregroundColor(.white)
                            }
                        }
                    }
                    Spacer()
                }
                .padding()
                .background(Color.black.opacity(0.6))
            }
            
            // Control panel
            VStack(spacing: 16) {
                HStack {
                    Text("受信ポート:")
                        .foregroundColor(.secondary)
                    
                    TextField("ポート番号", text: $port)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 100)
                        .keyboardType(.numberPad)
                        .disabled(isReceiving)
                        .submitLabel(.done)
                }
                .padding(.horizontal)
                
                Button(action: toggleReceiving) {
                    HStack {
                        Image(systemName: isReceiving ? "stop.circle.fill" : "play.circle.fill")
                        Text(isReceiving ? "受信停止" : "受信開始")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isReceiving ? Color.red : Color.green)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
                
                if isReceiving {
                    Text("h265_receiver.pyを使用して映像を受信してください")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
            .background(Color(UIColor.systemBackground))
        }
        .navigationBarTitle("端末B - ディスプレイ", displayMode: .inline)
        .onAppear {
            getDeviceIPAddress()
        }
        .alert("受信エラー", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func toggleReceiving() {
        if isReceiving {
            stopReceiving()
        } else {
            guard let portNumber = UInt16(port), portNumber > 0 else {
                alertMessage = "有効なポート番号を入力してください"
                showingAlert = true
                return
            }
            
            startReceiving(port: portNumber)
        }
    }
    
    private func startReceiving(port: UInt16) {
        isReceiving = true
        
        // TODO: Implement actual H.265 receiving logic here
        // For now, this is a placeholder
        // The actual implementation would:
        // 1. Create a UDP socket listening on the specified port
        // 2. Receive RTP packets
        // 3. Depacketize and decode H.265 NAL units
        // 4. Display the decoded frames
        
        // Simulate receiving (temporary)
        Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { timer in
            if !isReceiving {
                timer.invalidate()
                return
            }
            receivedFrames += 1
            receivedBytes += Int.random(in: 10000...50000)
        }
    }
    
    private func stopReceiving() {
        isReceiving = false
        // TODO: Clean up receiving resources
    }
    
    private func formatBytes(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func getDeviceIPAddress() {
        var address: String?
        
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0 else { return }
        guard let firstAddr = ifaddr else { return }
        
        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            let addr = ptr.pointee.ifa_addr.pointee
            
            if (flags & (IFF_UP|IFF_RUNNING|IFF_LOOPBACK)) == (IFF_UP|IFF_RUNNING) {
                if addr.sa_family == UInt8(AF_INET) || addr.sa_family == UInt8(AF_INET6) {
                    let name = String(cString: ptr.pointee.ifa_name)
                    if name == "en0" || name == "pdp_ip0" || name == "pdp_ip1" || name == "pdp_ip2" || name == "pdp_ip3" {
                        var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                        getnameinfo(ptr.pointee.ifa_addr, socklen_t(addr.sa_len), &hostname, socklen_t(hostname.count), nil, socklen_t(0), NI_NUMERICHOST)
                        address = String(cString: hostname)
                        if addr.sa_family == UInt8(AF_INET) {
                            break
                        }
                    }
                }
            }
        }
        
        freeifaddrs(ifaddr)
        
        DispatchQueue.main.async {
            deviceIPAddress = address ?? "Unknown"
        }
    }
}

#Preview {
    TerminalBDisplayView()
}