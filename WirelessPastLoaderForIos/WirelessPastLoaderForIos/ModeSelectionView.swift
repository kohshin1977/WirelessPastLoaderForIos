//
//  ModeSelectionView.swift
//  WirelessPastLoaderForIos
//
//  Created by 徳永功伸 on 2025/08/31.
//

import SwiftUI

struct ModeSelectionView: View {
    @State private var selectedMode: AppMode?
    
    enum AppMode {
        case terminalA
        case terminalB
    }
    
    var body: some View {
        NavigationView {
            VStack(spacing: 40) {
                Text("端末モード選択")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding(.top, 60)
                
                Text("この端末の役割を選択してください")
                    .font(.headline)
                    .foregroundColor(.secondary)
                
                Spacer()
                
                VStack(spacing: 30) {
                    NavigationLink(
                        destination: TerminalACameraView(),
                        tag: AppMode.terminalA,
                        selection: $selectedMode
                    ) {
                        ModeButton(
                            title: "端末A",
                            subtitle: "カメラ",
                            icon: "camera.fill",
                            description: "映像を送信",
                            color: .blue
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onTapGesture {
                        selectedMode = .terminalA
                    }
                    
                    NavigationLink(
                        destination: TerminalBDisplayView(),
                        tag: AppMode.terminalB,
                        selection: $selectedMode
                    ) {
                        ModeButton(
                            title: "端末B",
                            subtitle: "ディスプレイ",
                            icon: "tv.fill",
                            description: "映像を受信・表示",
                            color: .green
                        )
                    }
                    .buttonStyle(PlainButtonStyle())
                    .onTapGesture {
                        selectedMode = .terminalB
                    }
                }
                .padding(.horizontal, 30)
                
                Spacer()
                Spacer()
            }
            .navigationBarHidden(true)
        }
        .navigationViewStyle(StackNavigationViewStyle())
    }
}

struct ModeButton: View {
    let title: String
    let subtitle: String
    let icon: String
    let description: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 15) {
            HStack {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    
                    Text(subtitle)
                        .font(.title3)
                        .foregroundColor(.white.opacity(0.9))
                }
                
                Spacer()
                
                Image(systemName: icon)
                    .font(.system(size: 40))
                    .foregroundColor(.white)
            }
            .padding(.horizontal, 20)
            
            Text(description)
                .font(.body)
                .foregroundColor(.white.opacity(0.8))
        }
        .padding(.vertical, 25)
        .padding(.horizontal, 15)
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(color)
                .shadow(radius: 5)
        )
    }
}

#Preview {
    ModeSelectionView()
}