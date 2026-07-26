//
//  AlarmClockApp.swift
//  AlarmClock
//
//  @main エントリーポイント。
//    - AlarmAppState を StateObject として生成
//    - 起動時に bootstrap() で AlarmKit 権限リクエスト / TZ 監視 / スケジュール同期
//
//  v12 でシンプル化:
//    - RingingView / ringingAlarm 関連の fullScreenCover を削除
//    - scenePhase 変更時の checkAlerting / checkPendingPlayback 呼び出しを削除
//      (アラート UI は AlarmKit 標準の全画面 Alert に完全に任せる)
//    - ただし、StopAndOpenIntent 経由でアプリが再アクティブになるたびに
//      再度スケジュール同期 (= 次回のアラーム曲を抽選) は必要。
//      → onChange(scenePhase == .active) で bootstrap() 相当を再実行
//

import SwiftUI

@main
struct AlarmClockApp: App {

    @StateObject private var appState = AlarmAppState()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // TZ 補正の BGAppRefresh ハンドラは起動時に必ず register する必要がある。
        // nonisolated static なので @main init() から呼べる。
        TimeZoneWatcher.registerBackgroundTask()
    }

    var body: some Scene {
        WindowGroup {
            AlarmListView()
                .environmentObject(appState)
                .task {
                    await appState.bootstrap()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    if newPhase == .active {
                        // StopAndOpenIntent 経由で戻ってきた時に、次回のアラーム曲を
                        // 再抽選するため bootstrap を再実行 (idempotent)。
                        Task { await appState.bootstrap() }
                    }
                }
        }
    }
}
