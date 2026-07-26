//
//  BackgroundAlarmTasks.swift
//  AlarmClock
//
//  App Intent (停止 / スヌーズ) から呼ばれる、**アプリを起動せずに完結する処理**。
//
//  背景:
//    v25 までは停止 / スヌーズを押すと `openAppWhenRun = true` によって
//    アプリが前面に出て、AlarmAppState が再抽選やスヌーズ登録を行っていた。
//    しかし就寝中にアプリが立ち上がって画面が点くのは体験として良くない。
//
//    App Intent の `perform()` はアプリを起動しなくても実行される。
//    そこで必要な処理をここに集約し、Intent から直接呼ぶことで
//    「アプリを開かずにランダムアラームを継続する」を実現する。
//
//  ここで扱うもの:
//    - AlarmStorage       (UserDefaults 経由でアラーム一覧を読み書き)
//    - AlarmService       (AlarmKit への登録 / 解除)
//    - SoundLibraryService (音源の抽選と履歴)
//    いずれも v26 で `@MainActor` を外し、非同期文脈から使えるようにしてある。
//
//  注意:
//    App Intent の実行には時間制限がある。音源ファイルのコピーが発生する場合でも
//    通常は一瞬で終わるが、極端に大きなファイルだと間に合わない可能性がある。
//    処理の各段階は EventLog に記録するので、後から診断画面で追跡できる。
//

import AlarmKit
import Foundation

enum BackgroundAlarmTasks {

    // MARK: - 停止後の再抽選

    /// 停止されたアラームの「次回発火分」の音源を選び直す。
    ///
    /// 手順 (順序が重要):
    ///   1. 新しい ID を発行して、まず **新 ID で登録** する
    ///      (この時 prepareAlarmSound が走り、別の曲が選ばれる)
    ///   2. 登録が成功してから **旧 ID を削除** する
    ///
    /// cancel は AlarmKit 内部で非同期に処理されるため、同じ ID で
    /// cancel → schedule を連続させると競合して error 0 になる。
    /// ID を分けたうえで「登録 → 削除」の順にすることで、この競合を避けている。
    static func reshuffleAfterStop(alarmIDString: String) async {
        guard let oldID = UUID(uuidString: alarmIDString) else { return }

        let storage = AlarmStorage.shared
        var alarms = storage.load()

        guard let idx = alarms.firstIndex(where: { $0.id == oldID }) else {
            EventLog.log(.reshuffle, alarmID: oldID, message: "対象アラームが見つからず中止")
            return
        }
        let item = alarms[idx]

        // 繰り返さないアラーム (特定日 1 回のみ) は次回が無いので再抽選不要
        if case .oneShotAt = item.schedule {
            EventLog.log(.reshuffle, alarmID: oldID, message: "特定日1回のため再抽選せず")
            return
        }

        // ランダム抽選モード以外は音源が固定なので再抽選しても意味がない
        guard item.soundSourceMode == .random else {
            EventLog.log(.reshuffle, alarmID: oldID, message: "ランダム抽選モードでないため再抽選せず")
            return
        }

        let renewed = item.replacingID()
        EventLog.log(.reshuffle, alarmID: oldID,
                     message: "再抽選開始 (アプリ非起動) → 新ID=\(renewed.id.uuidString)")

        do {
            // 1. 新 ID で先に登録 (ここで別の曲が抽選される)
            try await AlarmService.shared.schedule(renewed)

            // 2. 登録できたので旧 ID を削除
            AlarmService.shared.cancel(id: oldID)

            // 3. 抽選履歴を引き継いで、連日同じ曲になるのを防ぐ
            SoundLibraryService.shared.migrateHistory(from: oldID, to: renewed.id)

            // 4. アプリ側の一覧を更新して保存
            //    (次にアプリを開いた時、bootstrap がこれを読み込む)
            alarms[idx] = renewed
            storage.save(alarms)

            EventLog.log(.reshuffle, alarmID: renewed.id,
                         message: "再抽選完了 (旧ID=\(oldID.uuidString) を解除)")
        } catch {
            // 失敗しても旧 ID の登録は生きているので、次回は同じ曲で鳴る。
            // アラームが鳴らなくなるわけではない。
            let ns = error as NSError
            EventLog.log(.reshuffle, alarmID: oldID,
                         message: "再抽選失敗 (旧登録は維持): \(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]")
        }
    }

    // MARK: - スヌーズ

    /// スヌーズが押されたアラームから「N 分後に鳴る一時アラーム」を作って登録する。
    ///
    /// secondaryButtonBehavior が `.custom` のため、AlarmKit は再鳴動を
    /// 面倒見てくれない。代わりにここで oneShotAt のアラームを登録する。
    /// 登録時に音源の抽選も走るので、スヌーズのたびに別の曲になる。
    static func createSnoozeInstance(alarmIDString: String) async {
        guard let sourceID = UUID(uuidString: alarmIDString) else { return }

        let storage = AlarmStorage.shared
        var alarms = storage.load()

        guard let source = alarms.first(where: { $0.id == sourceID }) else {
            EventLog.log(.snoozePress, alarmID: sourceID, message: "対象アラームが見つからず中止")
            return
        }

        // 元アラームを辿るためのキー
        let rootID = source.snoozeSourceID ?? source.id

        // 同じ元アラームに紐づく古いスヌーズインスタンスは片付ける
        // (スヌーズを連打しても常に 1 件だけ残るようにする)
        let stale = alarms.filter { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }
        for old in stale {
            AlarmService.shared.cancel(id: old.id)
        }
        alarms.removeAll { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }

        let instance = source.makingSnoozeInstance()
        EventLog.log(.snoozePress, alarmID: instance.id,
                     message: "スヌーズ登録開始 (アプリ非起動) \(String(format: "%02d:%02d", instance.hour, instance.minute))")

        do {
            try await AlarmService.shared.schedule(instance)
            alarms.append(instance)
            storage.save(alarms)
            EventLog.log(.snoozePress, alarmID: instance.id,
                         message: "スヌーズ登録完了 (\(source.snoozeMinutes) 分後)")
        } catch {
            let ns = error as NSError
            EventLog.log(.snoozePress, alarmID: instance.id,
                         message: "スヌーズ登録失敗: \(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]")
        }
    }
}
