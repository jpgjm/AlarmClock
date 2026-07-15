//
//  AlarmAppState.swift
//  AlarmClock
//
//  アプリ全体の中央 State。SwiftUI ビューが @EnvironmentObject で参照する。
//
//    - AlarmItem 一覧のロード / 追加 / 更新 / 削除
//    - 変更のたびに AlarmKit にスケジュールを同期する
//    - 発火中アラームの検出 (アプリ起動時に AlarmKit.alarms を確認し、
//      state == .alerting なら該当 AlarmItem を探して RingingView を出す)
//    - OpenAndPlayIntent が UserDefaults に書いた PendingPlaybackAlarmID を読んで
//      対応する AlarmItem のフォルダで音楽ランダム再生を開始する
//

import AlarmKit
import Combine
import Foundation
import SwiftUI

@MainActor
final class AlarmAppState: ObservableObject {

    @Published var alarms: [AlarmItem] = []
    /// 現在 UI で表示すべき発火中アラーム (RingingView に渡す)。nil なら通常画面。
    @Published var ringingAlarm: AlarmItem?

    private let storage = AlarmStorage.shared
    private let alarmService = AlarmService.shared
    private let audio = AudioPlayerService.shared
    private let tzWatcher = TimeZoneWatcher.shared

    // MARK: - Init / Bootstrap

    func bootstrap() async {
        alarms = storage.load()

        _ = await alarmService.ensureAuthorized()

        // AlarmKit 側と揃える
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

        // 発火中アラームは scenePhase active の時に checkAlerting() で拾う
        // (AlarmClockApp.swift 側で onChange を仕込んでいる)。
        checkAlerting()

        // 音楽ボタン (OpenAndPlayIntent) 起動時の pending をチェック
        checkPendingPlayback()
    }

    /// AlarmKit 側で .alerting になっているアラームがあれば、対応する AlarmItem を
    /// ringingAlarm に立てる → RingingView が sheet で表示される。
    func checkAlerting() {
        // AlarmManager.alarms は throws プロパティ
        let currentAlarms = (try? AlarmManager.shared.alarms) ?? []
        let alerting = currentAlarms.first { alarm in
            alarm.state == .alerting
        }
        guard let alerting else {
            // 全て解除されたら閉じる
            if audio.isPlaying == false {
                ringingAlarm = nil
            }
            return
        }
        if let match = alarms.first(where: { $0.id == alerting.id }) {
            ringingAlarm = match
        }
    }

    /// OpenAndPlayIntent がアプリを起動した場合、UserDefaults に書かれた ID を拾って
    /// フォルダから音楽ランダム再生を開始する。
    func checkPendingPlayback() {
        let defaults = UserDefaults.standard
        guard let idString = defaults.string(forKey: "PendingPlaybackAlarmID"),
              !idString.isEmpty,
              let uuid = UUID(uuidString: idString) else { return }
        defaults.removeObject(forKey: "PendingPlaybackAlarmID")

        guard let item = alarms.first(where: { $0.id == uuid }) else { return }

        // AlarmKit 側のアラート状態を stop する (音楽で置き換えるため)。stop は同期 throws。
        try? AlarmManager.shared.stop(id: item.id)

        // 音楽再生開始
        _ = audio.playRandom(
            folderRelPath: item.folderRelPath,
            volume: item.volume,
            fadeInSeconds: item.fadeInSeconds
        )
        ringingAlarm = item
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
        Task { await alarmService.syncSchedule(with: alarms) }
    }

    // MARK: - Ringing 制御 (アプリ内画面から呼ばれる)

    func stopRinging() {
        audio.stop()
        if let a = ringingAlarm {
            try? AlarmManager.shared.stop(id: a.id)
        }
        ringingAlarm = nil
    }

    /// スヌーズ: 音楽停止 + N 分後の oneShotAt アラームを新規登録。
    func snoozeRinging() {
        guard let a = ringingAlarm else { return }
        audio.stop()
        try? AlarmManager.shared.stop(id: a.id)

        let snoozeDate = Date().addingTimeInterval(TimeInterval(a.snoozeMinutes * 60))
        let snoozeItem = AlarmItem(
            hour: Calendar.current.component(.hour, from: snoozeDate),
            minute: Calendar.current.component(.minute, from: snoozeDate),
            schedule: .oneShotAt(date: snoozeDate),
            label: "スヌーズ (\(a.label.isEmpty ? "アラーム" : a.label))",
            folderRelPath: a.folderRelPath,
            volume: a.volume,
            fadeInSeconds: a.fadeInSeconds,
            snoozeEnabled: a.snoozeEnabled,
            snoozeMinutes: a.snoozeMinutes
        )
        addOrUpdate(snoozeItem)
        ringingAlarm = nil
    }
}
