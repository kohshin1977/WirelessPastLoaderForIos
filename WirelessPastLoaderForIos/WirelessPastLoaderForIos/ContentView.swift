//
//  ContentView.swift
//  WirelessPastLoaderForIos
//
//  Created by 徳永功伸 on 2025/08/30.
//

import SwiftUI
import AVFoundation

struct ContentView: View {
    @StateObject private var streamManager = CameraStreamManager()
    @State private var ipAddress = "192.168.0.68"
    @State private var port = "5004"
    @State private var isStreaming = false
    @State private var showingAlert = false
    @State private var alertMessage = ""
    @State private var deviceIPAddress = ""
    
    var body: some View {
        VStack(spacing: 0) {
            CameraPreviewView(previewLayer: streamManager.previewLayer)
                .ignoresSafeArea()
                .overlay(alignment: .top) {
                    VStack {
                        HStack {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("H.265 Video Transmitter")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                
                                if !deviceIPAddress.isEmpty {
                                    Text("Device IP: \(deviceIPAddress)")
                                        .font(.caption)
                                        .foregroundColor(.white)
                                }
                                
                                if isStreaming {
                                    HStack {
                                        Circle()
                                            .fill(Color.red)
                                            .frame(width: 8, height: 8)
                                        Text("Streaming to \(ipAddress):\(port)")
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
                }
            
            VStack(spacing: 16) {
                HStack {
                    TextField("IP Address", text: $ipAddress)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .submitLabel(.done)
                    
                    TextField("Port", text: $port)
                        .textFieldStyle(RoundedBorderTextFieldStyle())
                        .frame(width: 80)
                        .keyboardType(.numberPad)
                        .submitLabel(.done)
                }
                .padding(.horizontal)
                
                Button(action: toggleStreaming) {
                    HStack {
                        Image(systemName: isStreaming ? "stop.circle.fill" : "play.circle.fill")
                        Text(isStreaming ? "Stop Streaming" : "Start Streaming")
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(isStreaming ? Color.red : Color.blue)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            .padding(.vertical)
            .background(Color(UIColor.systemBackground))
        }
        .onAppear {
            requestCameraPermission()
            getDeviceIPAddress()
        }
        .alert("Stream Error", isPresented: $showingAlert) {
            Button("OK") { }
        } message: {
            Text(alertMessage)
        }
    }
    
    private func toggleStreaming() {
        if isStreaming {
            streamManager.stopStreaming()
            isStreaming = false
        } else {
            guard !ipAddress.isEmpty else {
                alertMessage = "Please enter an IP address"
                showingAlert = true
                return
            }
            
            guard let portNumber = UInt16(port), portNumber > 0 else {
                alertMessage = "Please enter a valid port number"
                showingAlert = true
                return
            }
            
            streamManager.startStreaming(host: ipAddress, port: portNumber)
            isStreaming = true
        }
    }
    
    private func requestCameraPermission() {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            if !granted {
                DispatchQueue.main.async {
                    alertMessage = "Camera access is required to stream video"
                    showingAlert = true
                }
            }
        }
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
    ContentView()
}
