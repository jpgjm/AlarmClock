//
//  OpenAndPlayIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert に配置する secondary button の実体。
//  `openAppWhenRun = true` により、Lock Screen や Dynamic Island のこのボタンを
//  タップするだけでアプリがフォアグラウンドに戻る。戻った時点で AppState が
//  発火中アラームの ID を検出し、指定フォルダの音楽ランダム再生を開始する。
//
//  参考: WWDC25 Session 230 のカスタム App Intent 例と同じ骨格。
//

import AppIntents
import Foundation

/// Alert から「音楽で起きる」ボタンが押されたときに実行される Intent。
/// 実体は「アプリを起動するだけ」。音楽再生は AppState 側で
/// `AlarmManager.shared.alarms` の状態を見て開始する。
struct OpenAndPlayIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "音楽で起きる"
    static var description = IntentDescription("アラームを止めてアプリを開き、音楽再生を開始します。")

    /// これが true だと Live Activity のボタンから実行されたときにアプリが前面に出る。
    static var openAppWhenRun: Bool = true

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        // 実体は openAppWhenRun による起動のみ。アプリ側で
        // `PendingPlaybackAlarmID` を UserDefaults 経由で拾って再生を開始する。
        UserDefaults.standard.set(alarmID, forKey: "PendingPlaybackAlarmID")
        return .result()
    }
}
