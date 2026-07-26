//
//  StopAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の stopButton に割り当てる Intent。
//
//  【v26 で挙動を変更】
//    `openAppWhenRun` を false にし、**アプリを開かずに** 次回分の再抽選を行う。
//
//    v25 まではアプリを前面に出して AlarmAppState に処理させていたが、
//    就寝中に画面が点くのは体験として良くない。App Intent の perform() は
//    アプリ非起動でも実行されるため、その中で完結させる方針に切り替えた。
//
//    型名に "AndOpen" が残っているのは、AlarmKit に登録済みのアラームとの
//    互換性を保つため (型名を変えると既存の登録が Intent を解決できなくなる恐れがある)。
//    実際にはもうアプリを開かない。
//
//  停止処理そのものについて:
//    stopIntent として呼ばれる時点で AlarmKit 側は既にアラートを止めている。
//    v23 のログで、ここで stop() を呼ぶと必ず失敗する
//    (AlarmKitCore.Alarm.AlarmError error 0) ことが判明したため呼んでいない。
//

import AlarmKit
import AppIntents
import Foundation

struct StopAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "停止"
    static var description = IntentDescription("アラームを停止し、次回のアラーム音を選び直します。")

    /// false にすることでアプリを起動せずに perform() だけが走る。
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
        EventLog.log(.stopPressed, alarmIDString: alarmID,
                     message: "停止ボタンが押された (アプリは開かない)")

        // アプリを起動せずに、次回発火分の音源を選び直す。
        await BackgroundAlarmTasks.reshuffleAfterStop(alarmIDString: alarmID)

        return .result()
    }
}
