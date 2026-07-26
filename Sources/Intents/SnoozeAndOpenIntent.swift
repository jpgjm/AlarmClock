//
//  SnoozeAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の secondaryButton (スヌーズ) に割り当てる Intent。
//
//  v17 の位置づけ (案 B の検証):
//    secondaryButtonBehavior を `.countdown` (AlarmKit ネイティブのスヌーズ) に戻した上で、
//    secondaryIntent としてこの Intent も渡している。
//
//    `.countdown` の時に secondaryIntent が呼ばれるかどうかは Apple の
//    ドキュメントに記載が無く、実機で確かめるしかない。そこでこの Intent は
//    「呼ばれた事実を UserDefaults に刻む」ことに専念する。
//    アプリ側 (AlarmAppState) がそれを読み取り、画面にバナーとして表示するので、
//    バナーが出れば呼ばれた / 出なければ無視された、と判別できる。
//
//  重要: ここで AlarmManager.stop(id:) を呼んではいけない。
//    `.countdown` では AlarmKit 自身が「アラート停止 → カウントダウン開始」を
//    処理する。こちらで stop すると、始まったばかりのカウントダウンごと
//    消してしまい、N 分後の再鳴動が起きなくなる恐れがある。
//    (v16 の `.custom` 実装では逆に stop が必須だった)
//

import AlarmKit
import AppIntents
import Foundation

struct SnoozeAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "スヌーズ"
    static var description = IntentDescription("スヌーズを記録してアプリを開きます。")

    /// true にすると Live Activity のボタンから実行された時にアプリが前面に出る。
    /// この Intent が実際に呼ばれるかどうかが v17 の検証ポイント。
    static var openAppWhenRun: Bool = true

    /// 呼ばれた対象アラームの ID を残す UserDefaults キー。
    static let pendingKey = "PendingSnoozeAlarmID"

    /// 呼ばれた時刻 (epoch 秒) を残す UserDefaults キー。検証バナーの表示に使う。
    static let firedAtKey = "PendingSnoozeFiredAt"

    @Parameter(title: "Alarm ID")
    var alarmID: String

    init() {
        self.alarmID = ""
    }

    init(alarmID: String) {
        self.alarmID = alarmID
    }

    func perform() async throws -> some IntentResult {
        // stop() は呼ばない (上記コメント参照)。
        // 呼ばれた痕跡だけを残し、あとはアプリ側に任せる。
        let defaults = UserDefaults.standard
        defaults.set(alarmID, forKey: Self.pendingKey)
        defaults.set(Date().timeIntervalSince1970, forKey: Self.firedAtKey)
        return .result()
    }
}
