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

import AlarmKit
import Combine
import Foundation

@MainActor
final class AlarmAppState: ObservableObject {

    @Published var alarms: [AlarmItem] = []

    private let storage = AlarmStorage.shared
    private let alarmService = AlarmService.shared
    private let tzWatcher = TimeZoneWatcher.shared

    // MARK: - Bootstrap

    func bootstrap() async {
        // Documents/AlarmSound/ と README.txt を用意 (存在すればスキップ)
        Self.ensureAlarmSoundFolder()

        alarms = storage.load()

        _ = await alarmService.ensureAuthorized()

        // AlarmKit 側と揃える (毎回全アラームを再登録)。
        // schedule() が prepareAlarmSound を呼ぶことで、翌回のアラーム曲が再抽選される。
        await alarmService.syncSchedule(with: alarms)

        // TZ 監視 3 層
        tzWatcher.onTimeZoneChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                await self.alarmService.syncSchedule(with: self.alarms)
            }
        }
        tzWatcher.checkOnLaunch()
        tzWatcher.startObserving()
        tzWatcher.scheduleNextBackgroundRefresh()
    }

    // MARK: - CRUD

    func addOrUpdate(_ item: AlarmItem) {
        if let idx = alarms.firstIndex(where: { $0.id == item.id }) {
            alarms[idx] = item
        } else {
            alarms.append(item)
        }
        persistAndSync()
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        alarmService.cancel(id: id)
        persistAndSync()
    }

    func toggleEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].enabled = enabled
        persistAndSync()
    }

    private func persistAndSync() {
        storage.save(alarms)
        Task {
            await alarmService.syncSchedule(with: alarms)
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
