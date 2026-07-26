//
//  StopAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の stopButton に割り当てる Intent。
//  Apple 公式サンプル AlarmKit-ScheduleAndAlert / AppIntents.swift の
//  StopIntent 準拠。
//
//  `openAppWhenRun = true` により、停止ボタンを押した瞬間にアプリがフォアグラウンドに
//  上がる。アプリ側はこれを合図に「鳴り終わったアラームの次回分を再抽選」する。
//

import AlarmKit
import AppIntents
import Foundation

struct StopAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止"
    static var description = IntentDescription("アラームを停止してアプリを開き、次回のアラーム音を選び直します。")

    /// true にすると Live Activity のボタンから実行された時にアプリが前面に出る。
    static var openAppWhenRun: Bool = true

    /// 停止されたアラーム ID をアプリ側へ渡す UserDefaults キー。
    /// AlarmAppState がこれを読んで「次回分の再抽選」を行う。
    static let stoppedKey = "StoppedAlarmID"

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        // 押された瞬間を記録する。
        // AlarmKit 側の発火タイミングと、アプリ起動後の処理を時系列で
        // 突き合わせられるようにするため、最初にログを残す。
        EventLog.log(.stopPressed, alarmIDString: alarmID, message: "停止ボタンが押された")

        // 鳴っているアラートを止める。
        //
        // ここは cancel ではなく stop が正しい。
        //   stop(id:)   = 鳴っているアラートを止める。繰り返しアラームの登録は残る
        //   cancel(id:) = 登録そのものを削除する (次回以降も鳴らなくなる)
        // 毎日鳴るアラームを 1 回止めただけで消えてしまっては困るため stop を使う。
        // (Apple 公式サンプルの StopIntent も stop を使用)
        if let uuid = UUID(uuidString: alarmID) {
            do {
                try AlarmManager.shared.stop(id: uuid)
                EventLog.log(.stopPressed, alarmIDString: alarmID, message: "stop() 成功")
            } catch {
                let ns = error as NSError
                EventLog.log(.stopPressed, alarmIDString: alarmID,
                             message: "stop() 失敗: \(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]")
            }
        }

        // 停止した ID を残しておく。
        // openAppWhenRun によってこの直後にアプリが起動し、
        // AlarmAppState.reshuffleStoppedAlarmIfNeeded() がこれを読んで
        // 次回発火分のアラーム音を選び直す。
        UserDefaults.standard.set(alarmID, forKey: Self.stoppedKey)

        return .result()
    }
}
