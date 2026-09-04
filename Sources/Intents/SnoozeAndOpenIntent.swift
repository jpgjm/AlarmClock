//
//  SnoozeAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の secondaryButton (スヌーズ) に割り当てる Intent。
//
//  【v26 で挙動を変更】
//    `openAppWhenRun` を false にし、**アプリを開かずに** スヌーズを成立させる。
//    N 分後に鳴る一時アラーム (スヌーズインスタンス) の登録も perform() 内で行う。
//
//    型名に "AndOpen" が残っているのは、AlarmKit に登録済みのアラームとの
//    互換性を保つため。
//
//  【v32 で LiveContainer 内での挙動を検証済み】
//    LiveContainer 内ではこの Intent が解決されず、スヌーズを押しても
//    **アラートが鳴り止まなかった** (.custom は Intent 内の stop() が必須のため)。
//    そのため LiveContainer 内では .custom を使わず、AlarmKit ネイティブの
//    .countdown にフォールバックする。これは機能制限ではなく安全策。
//
//  停止処理について:
//    secondaryButtonBehavior = .custom のスヌーズは、AlarmKit が
//    アラートの停止を行ってくれない。ここで明示的に stop() を呼ばないと
//    鳴り続けてしまうため、stopIntent 側とは異なり stop() を残している。
//

import AlarmKit
import AppIntents
import Foundation

struct SnoozeAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "スヌーズ"
    static var description = IntentDescription("アラームを止めて、指定分後に鳴り直すよう設定します。")

    /// false にすることでアプリを起動せずに perform() だけが走る。
    /// v32 で true にして検証したが LiveContainer 内では効果がなかったため戻した。
    static var openAppWhenRun: Bool = false

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        EventLog.log(.snoozePress, alarmIDString: alarmID,
                     message: "スヌーズボタンが押された (アプリは開かない)")

        // .custom behavior では AlarmKit が自動で止めてくれないため明示的に停止する。
        if let uuid = UUID(uuidString: alarmID) {
            do {
                try AlarmManager.shared.stop(id: uuid)
                EventLog.log(.snoozePress, alarmIDString: alarmID, message: "stop() 成功")
            } catch {
                let ns = error as NSError
                EventLog.log(.snoozePress, alarmIDString: alarmID,
                             message: "stop() 失敗: \(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]")
            }
        }

        // アプリを起動せずに N 分後のスヌーズインスタンスを登録する。
        await BackgroundAlarmTasks.createSnoozeInstance(alarmIDString: alarmID)

        return .result()
    }
}
