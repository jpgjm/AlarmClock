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

        // 【v24】ここで stop() を呼ばない。
        //
        // v23 のログで、この位置の stop() が必ず失敗していることが判明した:
        //   stop() 失敗: (AlarmKitCore.Alarm.AlarmError error 0.)
        //
        // stopIntent として登録した Intent が呼ばれる時点で、AlarmKit 側は
        // 既にアラートの停止処理を済ませている。そこへ重ねて stop() を呼ぶと
        // 「停止すべきものが無い」状態になり失敗する。
        // 実害は無いが、無用なエラーがログを埋めて原因追跡の妨げになるため外した。

        // 停止した ID を残しておく。
        // openAppWhenRun によってこの直後にアプリが起動し、
        // AlarmAppState.reshuffleStoppedAlarmIfNeeded() がこれを読んで
        // 次回発火分のアラーム音を選び直す。
        UserDefaults.standard.set(alarmID, forKey: Self.stoppedKey)

        return .result()
    }
}
