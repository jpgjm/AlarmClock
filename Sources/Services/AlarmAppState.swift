//
//  AlarmAppState.swift
//  AlarmClock
//
//  アプリ全体の中央 State。SwiftUI ビューが @EnvironmentObject で参照する。
//
//    - AlarmItem 一覧のロード / 追加 / 更新 / 削除
//    - 変更のたびに AlarmKit にスケジュールを同期する
//    - Documents/AlarmSound フォルダを起動時に作成
//
//  v12 でシンプル化:
//    - RingingView / ringingAlarm / snoozeRinging を削除 (AlarmKit 標準 UI に任せる)
//    - checkAlerting / checkPendingPlayback を削除 (音楽再生経路が無くなったため)
//    - AudioPlayerService への依存を削除
//
//  v16 でスヌーズを自前実装に変更:
//    - SnoozeAndOpenIntent が UserDefaults に書いた ID を bootstrap で拾い、
//      「N 分後に鳴る一時アラーム (スヌーズインスタンス)」を登録する
//    - スヌーズインスタンスは AlarmItem として保存されるが AlarmListView では非表示
//    - 発火時刻を過ぎたスヌーズインスタンスは bootstrap で自動削除
//

import AlarmKit
import Combine
import Foundation

@MainActor
final class AlarmAppState: ObservableObject {

    @Published var alarms: [AlarmItem] = []

    /// AlarmKit への登録に失敗したアラームの ID。行に警告アイコンを出すために使う。
    @Published var failedAlarmIDs: Set<UUID> = []

    /// 直近の登録失敗の内容。原因究明のため UI に表示する。
    @Published var lastScheduleFailureMessage: String?

    /// AlarmListView に表示すべきアラーム (スヌーズインスタンスを除外)。
    var visibleAlarms: [AlarmItem] {
        alarms.filter { !$0.isSnoozeInstance }
    }

    /// 現在有効なスヌーズインスタンス (発火待ち)。UI でバナー表示するために公開。
    var pendingSnoozeInstances: [AlarmItem] {
        let now = Date()
        return alarms.filter { $0.isSnoozeInstance && !$0.isExpiredSnoozeInstance(now: now) }
    }

    private let storage = AlarmStorage.shared
    private let alarmService = AlarmService.shared
    private let tzWatcher = TimeZoneWatcher.shared

    // MARK: - Bootstrap

    func bootstrap() async {
        EventLog.log(.bootstrap, message: "アプリ起動 / 同期開始")

        // Documents/AlarmSound/ と README.txt を用意 (存在すればスキップ)
        Self.ensureAlarmSoundFolder()

        alarms = storage.load()
        EventLog.log(.bootstrap, message: "保存済みアラーム \(alarms.count) 件を読み込み")

        // 発火時刻を過ぎたスヌーズインスタンスを掃除する。
        // (停止された / 鳴り終わったスヌーズが一覧データに残り続けないようにする)
        purgeExpiredSnoozeInstances()

        _ = await alarmService.ensureAuthorized()

        // AlarmKit 側と揃える。
        //   - アプリ側に無い / 無効化された登録は削除
        //   - 未登録のアラームだけを新規登録 (登録済みは触らない = 差分同期)
        // これにより「同じ ID で cancel → schedule」の競合が起きなくなる。
        let result = await alarmService.syncSchedule(with: alarms)
        applySyncResult(result)

        // 掃除やスヌーズ追加で alarms が変わっている可能性があるので保存し直す
        storage.save(alarms)

        let registered = alarmService.currentRegisteredAlarmStatesText().count
        EventLog.log(.bootstrap,
                     message: "同期完了 / アプリ側 \(alarms.count) 件・AlarmKit \(registered) 件・失敗 \(result.failedIDs.count) 件")

        // TZ 監視 3 層
        tzWatcher.onTimeZoneChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                let r = await self.alarmService.syncSchedule(with: self.alarms)
                self.applySyncResult(r)
            }
        }
        tzWatcher.checkOnLaunch()
        tzWatcher.startObserving()
        tzWatcher.scheduleNextBackgroundRefresh()
    }

    // MARK: - スヌーズ (v16)

    /// 発火時刻を過ぎたスヌーズインスタンスを一覧から取り除く。
    private func purgeExpiredSnoozeInstances(now: Date = Date()) {
        let expired = alarms.filter { $0.isExpiredSnoozeInstance(now: now) }
        guard !expired.isEmpty else { return }
        for item in expired {
            alarmService.cancel(id: item.id)
        }
        alarms.removeAll { $0.isExpiredSnoozeInstance(now: now) }
        debugPrint("[Snooze] purged \(expired.count) expired instance(s)")
    }

    /// 指定した元アラームに紐づくスヌーズを取り消す (ユーザーが手動でキャンセルする用)。
    func cancelSnooze(forRootID rootID: UUID) {
        let targets = alarms.filter { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }
        for item in targets {
            alarmService.cancel(id: item.id)
        }
        alarms.removeAll { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }
        persistAndSync()
    }

    // MARK: - CRUD

    /// アラームを追加、または既存アラームを更新する。
    ///
    /// 【重要】既存アラームの更新時は **ID を振り直す**。
    ///   v22 で syncSchedule を差分同期 (既に登録済みの ID は触らない) にしたため、
    ///   同じ ID のままだと「登録済み」と判定されて編集内容が反映されない。
    ///   新しい ID にすることで未登録扱いになり、確実に登録し直される。
    ///
    ///   なお cancel(oldID) と schedule(newID) は ID が異なるため、
    ///   AlarmKit 内部の非同期処理が競合することはない。
    ///   (同じ ID で cancel → schedule を連続させると error 0 になる)
    func addOrUpdate(_ item: AlarmItem) {
        let timeText = String(format: "%02d:%02d", item.hour, item.minute)

        if let idx = alarms.firstIndex(where: { $0.id == item.id }) {
            let oldID = item.id
            let renewed = item.replacingID()

            // 古い登録と prepared 音源を確実に片付ける
            alarmService.cancel(id: oldID)

            // 抽選履歴を新 ID に引き継ぐ
            SoundLibraryService.shared.migrateHistory(from: oldID, to: renewed.id)

            alarms[idx] = renewed
            EventLog.log(.update, alarmID: renewed.id,
                         message: "編集して保存 \(timeText) / \(item.scheduleLabel()) / 旧ID=\(oldID.uuidString)")
        } else {
            alarms.append(item)
            EventLog.log(.create, alarmID: item.id,
                         message: "新規作成 \(timeText) / \(item.scheduleLabel()) / モード=\(Self.modeText(item.soundSourceMode))")
        }
        persistAndSync()
    }

    /// ログ表示用のモード名。
    private static func modeText(_ mode: SoundSourceMode) -> String {
        switch mode {
        case .defaultSound: return "デフォルト"
        case .fixed:        return "特定の音源"
        case .random:       return "ランダム抽選"
        }
    }

    func delete(_ id: UUID) {
        EventLog.log(.delete, alarmID: id, message: "アラームを削除")

        // 紐づくスヌーズインスタンスも道連れに削除する
        // (元アラームを消したのにスヌーズだけ鳴る、という状態を防ぐ)
        let related = alarms.filter { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == id }
        for item in related {
            alarmService.cancel(id: item.id)
        }
        alarms.removeAll { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == id }

        alarms.removeAll { $0.id == id }
        alarmService.cancel(id: id)
        persistAndSync()
    }

    /// アラームの有効 / 無効を切り替える。
    ///
    /// 有効化する際は addOrUpdate と同じ理由で ID を振り直す。
    /// 無効化で一度 stop した ID を再利用すると、AlarmKit 側で正しく
    /// 発火しなくなる可能性があるため。
    func toggleEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }

        if enabled {
            // 無効 → 有効: ID を振り直して新規登録扱いにする
            var item = alarms[idx]
            item.enabled = true
            let renewed = item.replacingID()

            alarmService.cancel(id: id)
            SoundLibraryService.shared.migrateHistory(from: id, to: renewed.id)

            alarms[idx] = renewed
            EventLog.log(.toggle, alarmID: renewed.id,
                         message: "有効化 (ID 振り直し) / 旧ID=\(id.uuidString)")
        } else {
            // 有効 → 無効: 登録は syncSchedule の削除ループが解除する
            alarms[idx].enabled = false
            EventLog.log(.toggle, alarmID: id, message: "無効化")
        }

        persistAndSync()
    }

    private func persistAndSync() {
        storage.save(alarms)
        Task {
            let result = await alarmService.syncSchedule(with: alarms)
            applySyncResult(result)
        }
    }

    /// 同期結果を UI 用の State に反映する。
    /// 登録に失敗したアラームがあれば一覧に警告を出し、原因の手掛かりも表示する。
    private func applySyncResult(_ result: AlarmSyncResult) {
        failedAlarmIDs = result.failedIDs
        lastScheduleFailureMessage = result.lastFailureMessage
    }

    /// 登録失敗の警告を閉じる。
    func dismissScheduleFailure() {
        failedAlarmIDs.removeAll()
        lastScheduleFailureMessage = nil
    }

    // MARK: - Documents/AlarmSound フォルダの初期化

    /// Documents/AlarmSound フォルダと使い方の README.txt を配置する。
    /// 存在していればスキップ。ユーザーが Files アプリでオーディオを配置するための場所。
    private static func ensureAlarmSoundFolder() {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
        let folder = docs.appendingPathComponent("AlarmSound", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            debugPrint("Failed to create AlarmSound folder: \(error)")
            return
        }

        let readme = folder.appendingPathComponent("README.txt")
        if fm.fileExists(atPath: readme.path) { return }

        let text = """
        このフォルダに再生したいオーディオファイルを入れてください。

        対応形式: .wav / .aiff / .caf (推奨) / .mp3 / .m4a / .aac
        flac は AlarmKit 非対応のため除外されます。

        サブフォルダを作って整理しても構いません。
        フォルダ内 (再帰) からランダムに 1 曲選ばれてアラーム音として鳴ります。
        アプリを開くたびに翌回の曲がランダムに切り替わります。

        なお、iOS 26.0 では MP3 / M4A が壊れているバグの報告があります (26.1+ で改善)。
        安定して鳴らしたい場合は WAV / AIFF / CAF を使ってください。
        """
        try? text.data(using: .utf8)?.write(to: readme)
    }
}
