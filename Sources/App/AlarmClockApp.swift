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
        // 起動を記録する。
        //
        //   ヘッドレス起動 (LiveProcess 経由) ではシーンが接続されないため、
        //   .task も .onChange(scenePhase) も発火しない。
        //   init() なら UIApplicationMain の途中で必ず走るので、
        //   どちらの経路でも記録が残る。
        //
        //   画面が出ない実行では、これが唯一の観測手段になる。
        LaunchTrace.record("init")

        // TZ 補正の BGAppRefresh ハンドラは起動時に必ず register する必要がある。
        // nonisolated static なので @main init() から呼べる。
        TimeZoneWatcher.registerBackgroundTask()

        // 【v37】LiveProcess 経由で画面なしに起動された場合の処理。
        //
        //   v36 の実測で、この init() までヘッドレスでも到達することが
        //   確認できた (痕跡に reason=init が記録された)。
        //   なので C の constructor に押し込む必要はなく、
        //   Swift のコードをそのまま書ける。
        //
        //   通常起動やマルチタスク表示では何もしない。
        HeadlessRunner.runIfNeeded()
    }

    var body: some Scene {
        WindowGroup {
            AlarmListView()
                .environmentObject(appState)
                .task {
                    // 【v37】シーンが接続されたことを HeadlessRunner に伝える。
                    //   マルチタスク表示中に exit(0) されないようにするため。
                    HeadlessRunner.markSceneConnected()
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
