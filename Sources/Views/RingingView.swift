//
//  RingingView.swift
//  AlarmClock
//
//  アラーム発火中 (音楽再生中) にフルスクリーンで出す UI。
//    - 停止ボタン (音楽と AlarmKit のアラート両方止める)
//    - スヌーズボタン (スヌーズ有効時のみ)
//    - 音量スライダー (即時反映)
//    - 現在再生中のタイトル / アーティスト
//    - 現在時刻
//

import SwiftUI

struct RingingView: View {
    let alarm: AlarmItem

    @EnvironmentObject private var appState: AlarmAppState
    @ObservedObject private var audio = AudioPlayerService.shared

    @State private var volume: Double
    @State private var now: Date = Date()

    private let clockTimer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    init(alarm: AlarmItem) {
        self.alarm = alarm
        _volume = State(initialValue: alarm.volume)
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 20) {
                Spacer(minLength: 20)

                Image(systemName: "bell.and.waves.left.and.right.fill")
                    .font(.system(size: 56))
                    .foregroundStyle(.orange)

                Text(alarm.label.isEmpty ? "アラーム" : alarm.label)
                    .font(.title3)
                    .foregroundStyle(.white.opacity(0.8))

                Text(timeString(now))
                    .font(.system(size: 76, weight: .light, design: .rounded))
                    .foregroundStyle(.white)

                Spacer()

                VStack(spacing: 6) {
                    Image(systemName: "music.note")
                        .foregroundStyle(.white.opacity(0.3))
                        .font(.title)
                    Text(audio.currentTitle.isEmpty ? "音楽を読み込み中…" : audio.currentTitle)
                        .foregroundStyle(.white)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                    if !audio.currentArtist.isEmpty {
                        Text(audio.currentArtist)
                            .foregroundStyle(.white.opacity(0.6))
                            .font(.footnote)
                    }
                }
                .padding(.horizontal, 32)

                Spacer()

                HStack {
                    Image(systemName: "speaker.wave.1").foregroundStyle(.white.opacity(0.7))
                    Slider(value: $volume, in: 0...1) { _ in
                        audio.setVolume(volume)
                    }
                    .tint(.orange)
                    Image(systemName: "speaker.wave.3").foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 24)

                HStack(spacing: 12) {
                    if alarm.snoozeEnabled {
                        Button {
                            appState.snoozeRinging()
                        } label: {
                            VStack {
                                Text("スヌーズ").font(.headline)
                                Text("\(alarm.snoozeMinutes) 分後")
                                    .font(.caption)
                            }
                            .frame(maxWidth: .infinity, minHeight: 64)
                            .foregroundStyle(.white)
                        }
                        .buttonStyle(.bordered)
                        .tint(.white)
                    }

                    Button {
                        appState.stopRinging()
                    } label: {
                        Text("停止")
                            .font(.headline)
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.orange)
                }
                .padding(.horizontal, 24)
                .padding(.bottom, 32)
            }
        }
        .onReceive(clockTimer) { now = $0 }
        .interactiveDismissDisabled()
    }

    private func timeString(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
}
