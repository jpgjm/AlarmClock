//
//  SnoozeAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の secondaryButton (スヌーズ) に割り当てる Intent。
//  StopAndOpenIntent と同じ骨格で、`openAppWhenRun = true` によりアプリを前面に出す。
//
//  v16 での方針転換:
//    v15 まではスヌーズを AlarmKit ネイティブ (.countdown behavior) に任せていたが、
//    その場合アプリが起動しないため
//      - スヌーズ再鳴動時に同じ曲が鳴り続ける
//      - 次回アラームの抽選も走らない
//    という制約があった。
//
//    v16 では .custom behavior + この Intent に切り替え、押下時にアプリを開いて
//    「N 分後に鳴る一時アラーム (スヌーズインスタンス)」を自前で登録する。
//    登録時に prepareAlarmSound() が走るので、スヌーズのたびに別の曲が選ばれる。
//
//  トレードオフ:
//    スヌーズを押すたびにアプリが前面に出る (画面が点く)。
//    AlarmKit のネイティブなカウントダウン表示は使われなくなる。
//
//  アプリ側の受け取り:
//    ここでは UserDefaults に対象 ID を書くだけ。実際の再スケジュールは
//    AlarmAppState.applyPendingSnoozeIfNeeded() が行う (アプリ起動後に実行される)。
//

import AlarmKit
import AppIntents
import Foundation

struct SnoozeAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "スヌーズ"
    static var description = IntentDescription("アラームを止めてアプリを開き、指定分後に鳴り直すよう再設定します。")

    /// true にすると Live Activity のボタンから実行された時にアプリが前面に出る。
    static var openAppWhenRun: Bool = true

    /// アプリ側が pending スヌーズを受け取るための UserDefaults キー。
    static let pendingKey = "PendingSnoozeAlarmID"

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        // 押された瞬間を記録する (時系列の突き合わせ用)。
        EventLog.log(.snoozePress, alarmIDString: alarmID, message: "スヌーズボタンが押された")

        // 鳴っているアラームを停止する。
        //
        // stopIntent (StopAndOpenIntent) では v24 でこの呼び出しを外したが、
        // こちらは事情が異なるので残している:
        //   停止ボタンは AlarmKit が自動でアラートを止めてくれるのに対し、
        //   secondaryButtonBehavior = .custom のスヌーズは AlarmKit が
        //   何もしないため、明示的に止めないと鳴り続けてしまう。
        //
        // ここでも失敗するようなら (ログで確認できる) 外す判断をする。
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

        // アプリ側で拾えるように対象 ID を残しておく。
        // openAppWhenRun によってこの直後にアプリが起動し、
        // AlarmAppState.applyPendingSnoozeIfNeeded() がこれを読んで再スケジュールする。
        UserDefaults.standard.set(alarmID, forKey: Self.pendingKey)

        return .result()
    }
}
