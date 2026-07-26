//
//  StopAndOpenIntent.swift
//  AlarmClock
//
//  AlarmKit の Alert の stopButton に割り当てる Intent。
//  Apple 公式サンプル SchedulingAnAlarmWithAlarmKit / AppIntents.swift の
//  StopIntent 準拠。
//
//  `openAppWhenRun = true` により、停止ボタンを押した瞬間にアプリがフォアグラウンドに
//  上がる。アプリ起動時 (AlarmClockApp.onAppear → AlarmAppState.bootstrap) で
//  syncSchedule が走り、繰り返しアラームの "次回発火用の prepared 音源" が
//  自動的に再抽選される。
//
//  こうすることで、ユーザーが「停止」だけしても翌回のアラーム音がシャッフルされる。
//  従来 (v9 まで) は「音楽で起きる」ボタンを押すか、後で手動でアプリを開かない限り
//  同じ曲が続いていた挙動を解消する。
//

import AlarmKit
import AppIntents
import Foundation

struct StopAndOpenIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "止める"
    static var description = IntentDescription("アラームを停止してアプリを開き、次回のアラーム音を再抽選します。")

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
        // AlarmKit の該当アラームを明示的に停止する。
        // (stopIntent を指定した場合、AlarmKit のデフォルトの stop 挙動は自動的には
        //  走らない可能性があるため、ここで確実に stop を呼ぶ。stop は同期 throws。)
        if let uuid = UUID(uuidString: alarmID) {
            try? AlarmManager.shared.stop(id: uuid)
        }
        // その後、openAppWhenRun によってアプリが起動する。
        // アプリ起動時 (bootstrap → syncSchedule → schedule → prepareAlarmSound)
        // で次回の曲がランダム抽選される。
        return .result()
    }
}
