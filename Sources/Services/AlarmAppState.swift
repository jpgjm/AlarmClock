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

    /// スヌーズを受け付けた直後に UI へ知らせるためのメッセージ。
    /// 例: 「5 分後に再通知します (7:35)」。表示後は nil に戻す。
    @Published var snoozeNotice: String?

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

        // SnoozeAndOpenIntent が書いた pending があれば、ここでスヌーズを成立させる。
        // syncSchedule より前に呼ぶことで、新しいスヌーズインスタンスも同じ同期で登録される。
        applyPendingSnoozeIfNeeded()

        _ = await alarmService.ensureAuthorized()

        // AlarmKit 側と揃える。
        //   - アプリ側に無い / 無効化された登録は削除
        //   - 未登録のアラームだけを新規登録 (登録済みは触らない = 差分同期)
        // これにより「同じ ID で cancel → schedule」の競合が起きなくなる。
        let result = await alarmService.syncSchedule(with: alarms)
        applySyncResult(result)

        // 直前に停止されたアラームがあれば、次回発火分の音源を選び直す。
        // syncSchedule の後に呼ぶことで、登録済み判定と衝突しない。
        await reshuffleStoppedAlarmIfNeeded()

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

    /// SnoozeAndOpenIntent が UserDefaults に書いた対象 ID を読み取り、
    /// 「N 分後に鳴るスヌーズインスタンス」を作って一覧に加える。
    ///
    /// 対象 ID は「元アラーム」「既存のスヌーズインスタンス」どちらの場合もある。
    /// どちらでも `makingSnoozeInstance()` が適切に snoozeSourceID を引き継ぐ。
    private func applyPendingSnoozeIfNeeded() {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: SnoozeAndOpenIntent.pendingKey),
              !idString.isEmpty,
              let uuid = UUID(uuidString: idString) else { return }

        // 二重適用を防ぐため、読み取ったら即座に消す
        defaults.removeObject(forKey: SnoozeAndOpenIntent.pendingKey)

        guard let source = alarms.first(where: { $0.id == uuid }) else {
            debugPrint("[Snooze] pending ID が見つかりません: \(idString)")
            return
        }

        // 元アラームを辿るためのキー
        let rootID = source.snoozeSourceID ?? source.id

        // 同じ元アラームに紐づく古いスヌーズインスタンスは片付ける
        // (スヌーズを連打しても常に 1 件だけ残るようにする)
        let stale = alarms.filter { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }
        for item in stale {
            alarmService.cancel(id: item.id)
        }
        alarms.removeAll { $0.isSnoozeInstance && ($0.snoozeSourceID ?? $0.id) == rootID }

        // 新しいスヌーズインスタンスを追加
        let instance = source.makingSnoozeInstance()
        alarms.append(instance)

        // UI 通知用の文言を組み立てる
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm"
        if case .oneShotAt(let date) = instance.schedule {
            snoozeNotice = "\(source.snoozeMinutes) 分後 (\(f.string(from: date))) に再通知します"
        } else {
            snoozeNotice = "\(source.snoozeMinutes) 分後に再通知します"
        }

        debugPrint("[Snooze] instance created: \(instance.id) fires at \(instance.hour):\(instance.minute)")
    }

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

    /// スヌーズ通知バナーを閉じる。
    func dismissSnoozeNotice() {
        snoozeNotice = nil
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

    // MARK: - 停止後の再抽選 (v22)

    /// 直前に停止されたアラームの「次回発火分」の音源を選び直す。
    ///
    /// v22 で syncSchedule を差分同期にしたため、アプリ起動のたびに全アラームを
    /// 登録し直すことはしなくなった。その代わり、アラームが鳴って停止された
    /// タイミングでだけ、そのアラームの音源を抽選し直す。
    ///
    /// 手順 (順序が重要):
    ///   1. 新しい ID を発行して、まず **新 ID で登録** する
    ///      (この時 prepareAlarmSound が走り、別の曲が選ばれる)
    ///   2. 登録が成功してから **旧 ID を削除** する
    ///
    /// cancel は AlarmKit 内部で非同期に処理されるため、同じ ID で
    /// cancel → schedule を連続させると競合して error 0 になる。
    /// ID を分けたうえで「登録 → 削除」の順にすることで、この競合を避けている。
    private func reshuffleStoppedAlarmIfNeeded() async {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: StopAndOpenIntent.stoppedKey),
              !idString.isEmpty,
              let oldID = UUID(uuidString: idString) else { return }

        // 二重実行を防ぐため、読み取ったら即座に消す
        defaults.removeObject(forKey: StopAndOpenIntent.stoppedKey)

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
        EventLog.log(.reshuffle, alarmID: oldID, message: "再抽選開始 → 新ID=\(renewed.id.uuidString)")

        do {
            // 1. 新 ID で先に登録 (ここで別の曲が抽選される)
            try await alarmService.schedule(renewed)

            // 2. 登録できたので旧 ID を削除
            alarmService.cancel(id: oldID)

            // 3. 抽選履歴を引き継いで、連日同じ曲になるのを防ぐ
            SoundLibraryService.shared.migrateHistory(from: oldID, to: renewed.id)

            alarms[idx] = renewed
            storage.save(alarms)
            EventLog.log(.reshuffle, alarmID: renewed.id, message: "再抽選完了 (旧ID=\(oldID.uuidString) を解除)")
        } catch {
            // 失敗しても旧 ID の登録は生きているので、次回は同じ曲で鳴る。
            // アラームが鳴らなくなるわけではないため、エラー表示はしない。
            let ns = error as NSError
            EventLog.log(.reshuffle, alarmID: oldID,
                         message: "再抽選失敗 (旧登録は維持): \(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]")
        }
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
