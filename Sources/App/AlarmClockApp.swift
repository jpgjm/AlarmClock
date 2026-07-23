//
//  AlarmClockApp.swift
//  AlarmClock
//
//  @main エントリーポイント。
//    - AlarmAppState を StateObject として生成
//    - 起動時に bootstrap() で AlarmKit 権限リクエスト / TZ 監視 / 発火チェック
//    - scenePhase が .active になるたびに再チェック (Live Activity のボタンから
//      戻ってきたケースを拾う)
//

import SwiftUI

@main
struct AlarmClockApp: App {

    @StateObject private var appState = AlarmAppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // v7 では Info.plist から BGTaskSchedulerPermittedIdentifiers を削除しているため、
        // BGTaskScheduler.shared.register() は呼ばない (無害化)。
        // TZ 補正はアプリ起動時と scenePhase active のたびのチェックのみで動作する。
        // TimeZoneWatcher.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        appState.checkAlerting()
                        appState.checkPendingPlayback()
                    }
                }
        }
    }
}

/// AlarmListView をベースに、発火中の時だけ RingingView をフルスクリーンで被せる。
struct RootView: View {
    @EnvironmentObject private var appState: AlarmAppState

    var body: some View {
        AlarmListView()
            .fullScreenCover(item: Binding(
                get: { appState.ringingAlarm },
                set: { new in
                    // ユーザーがシステム操作で閉じた場合は stopRinging と等価
                    if new == nil && appState.ringingAlarm != nil {
                        appState.stopRinging()
                    }
                }
            )) { alarm in
                RingingView(alarm: alarm)
                    .environmentObject(appState)
            }
    }
}
