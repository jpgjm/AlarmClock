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
//  v17 で案 B の検証構成に変更:
//    - スヌーズは AlarmKit ネイティブ (.countdown) に戻したため、
//      スヌーズインスタンスの自動生成は行わない
//    - 代わりに SnoozeAndOpenIntent が呼ばれたかどうかを記録し、
//      AlarmListView に検証バナーとして表示する
//    - Intent が呼ばれた直後の同期では、その ID を skipIDs に入れて
//      カウントダウンを壊さないようにする
//    - v16 のスヌーズインスタンス機構 (isSnoozeInstance など) は
//      将来 .custom に戻す可能性を考えてデータモデルには残してある
//

import AlarmKit
import Combine
import Foundation

@MainActor
final class AlarmAppState: ObservableObject {

    @Published var alarms: [AlarmItem] = []

    /// 案 B の検証結果。SnoozeAndOpenIntent が呼ばれた時に文字列が入る。
    /// これが表示されれば `.countdown` でも secondaryIntent が呼ばれる、と確認できる。
    @Published var snoozeIntentReport: String?

    /// AlarmListView に表示すべきアラーム (スヌーズインスタンスを除外)。
    /// v17 ではスヌーズインスタンスを作らないので実質すべて表示されるが、
    /// v16 で作られた残骸が UserDefaults に残っている場合に備えてフィルタは残す。
    var visibleAlarms: [AlarmItem] {
        alarms.filter { !$0.isSnoozeInstance }
    }

    private let storage = AlarmStorage.shared
    private let alarmService = AlarmService.shared
    private let tzWatcher = TimeZoneWatcher.shared

    /// 直近のスヌーズでカウントダウンが進行中と思われるアラーム ID。
    /// 次の syncSchedule で再登録をスキップして、カウントダウンを保護する。
    private var countdownInProgressIDs: Set<UUID> = []

    // MARK: - Bootstrap

    func bootstrap() async {
        // Documents/AlarmSound/ と README.txt を用意 (存在すればスキップ)
        Self.ensureAlarmSoundFolder()

        alarms = storage.load()

        // v16 で作られたスヌーズインスタンスが残っていれば掃除しておく。
        // v17 では新規に作られることはないが、アップグレード直後は残骸がありうる。
        purgeLegacySnoozeInstances()

        // SnoozeAndOpenIntent が呼ばれていたかを確認する (案 B の検証ポイント)。
        checkSnoozeIntentReport()

        _ = await alarmService.ensureAuthorized()

        // AlarmKit 側と揃える (毎回全アラームを再登録)。
        // schedule() が prepareAlarmSound を呼ぶことで、翌回のアラーム曲が再抽選される。
        //
        // ただしスヌーズ直後は、そのアラームのカウントダウンが進行中の可能性がある。
        // 再登録するとカウントダウンが巻き戻る / 消える恐れがあるためスキップする。
        await alarmService.syncSchedule(with: alarms, skipIDs: countdownInProgressIDs)

        // 掃除で alarms が変わっている可能性があるので保存し直す
        storage.save(alarms)

        // TZ 監視 3 層
        tzWatcher.onTimeZoneChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.alarmService.syncSchedule(with: self.alarms, skipIDs: self.countdownInProgressIDs)
            }
        }
        tzWatcher.checkOnLaunch()
        tzWatcher.startObserving()
        tzWatcher.scheduleNextBackgroundRefresh()
    }

    // MARK: - スヌーズ Intent の検証 (v17 / 案 B)

    /// SnoozeAndOpenIntent が呼ばれた痕跡を UserDefaults から読み取り、
    /// 画面に表示する検証メッセージを組み立てる。
    ///
    /// 案 B の検証はここが要:
    ///   - このメッセージが表示される → `.countdown` でも secondaryIntent は呼ばれる
    ///   - 表示されない (アプリすら開かない) → `.countdown` では無視される
    private func checkSnoozeIntentReport() {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: SnoozeAndOpenIntent.pendingKey),
              !idString.isEmpty else { return }

        let firedAt = defaults.double(forKey: SnoozeAndOpenIntent.firedAtKey)

        // 二重表示を防ぐため、読み取ったら消す
        defaults.removeObject(forKey: SnoozeAndOpenIntent.pendingKey)
        defaults.removeObject(forKey: SnoozeAndOpenIntent.firedAtKey)

        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss"
        let timeText = firedAt > 0
            ? f.string(from: Date(timeIntervalSince1970: firedAt))
            : "時刻不明"

        // 対象アラームのラベルを解決 (見つからなければ ID の先頭だけ表示)
        let label: String
        if let uuid = UUID(uuidString: idString),
           let item = alarms.first(where: { $0.id == uuid }) {
            label = item.label.isEmpty ? String(format: "%02d:%02d", item.hour, item.minute) : item.label
            // このアラームはカウントダウン進行中の可能性が高いので、再登録から保護する
            countdownInProgressIDs.insert(uuid)
        } else {
            label = String(idString.prefix(8))
        }

        snoozeIntentReport = "✅ .countdown でも secondaryIntent が呼ばれました\n対象: \(label) / 時刻: \(timeText)"
        debugPrint("[CaseB] SnoozeAndOpenIntent was invoked for \(idString) at \(timeText)")
    }

    /// 検証バナーを閉じる。閉じた時点でカウントダウン保護も解除する
    /// (ユーザーがバナーを読んだ = スヌーズの様子を確認できる状態、と見なす)。
    func dismissSnoozeIntentReport() {
        snoozeIntentReport = nil
        countdownInProgressIDs.removeAll()
    }

    /// v16 で生成されたスヌーズインスタンスの残骸を取り除く。
    /// v17 では AlarmKit ネイティブのカウントダウンを使うため不要になった。
    private func purgeLegacySnoozeInstances() {
        let legacy = alarms.filter { $0.isSnoozeInstance }
        guard !legacy.isEmpty else { return }
        for item in legacy {
            alarmService.cancel(id: item.id)
        }
        alarms.removeAll { $0.isSnoozeInstance }
        debugPrint("[Snooze] purged \(legacy.count) legacy instance(s) from v16")
    }

    // MARK: - CRUD

    func addOrUpdate(_ item: AlarmItem) {
        if let idx = alarms.firstIndex(where: { $0.id == item.id }) {
            alarms[idx] = item
        } else {
            alarms.append(item)
        }
        // 明示的に編集されたアラームは、変更を確実に反映させるため保護対象から外す
        countdownInProgressIDs.remove(item.id)
        persistAndSync()
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        alarmService.cancel(id: id)
        countdownInProgressIDs.remove(id)
        persistAndSync()
    }

    func toggleEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].enabled = enabled
        countdownInProgressIDs.remove(id)
        persistAndSync()
    }

    private func persistAndSync() {
        storage.save(alarms)
        Task {
            // カウントダウン進行中のアラームは再登録しない (スヌーズを壊さないため)
            await alarmService.syncSchedule(with: alarms, skipIDs: countdownInProgressIDs)
        }
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
