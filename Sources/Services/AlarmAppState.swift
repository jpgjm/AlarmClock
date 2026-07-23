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
//    - AlarmKit の認可状態 / スケジュール失敗を UI に露出する
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

    /// AlarmKit の認可状態。UI 警告バナー用。
    @Published var authorizationDenied: Bool = false

    /// スケジュールに失敗した AlarmItem の ID 集合。行に赤マーク等を出すため。
    @Published var failedAlarmIDs: Set<UUID> = []

    /// 直近のスケジュール失敗のエラーメッセージ (デバッグ手掛かり用)。
    /// UI 警告バナーで表示する。
    @Published var lastScheduleFailureMessage: String?

    /// 一過性の警告メッセージ (再生対象が0件・音楽ライブラリの解決失敗など)。
    /// UI では banner または alert として表示する。
    @Published var transientWarning: String?

    private let storage = AlarmStorage.shared
    private let alarmService = AlarmService.shared
    private let audio = AudioPlayerService.shared
    private let tzWatcher = TimeZoneWatcher.shared

    // MARK: - Init / Bootstrap

    func bootstrap() async {
        // Documents/AlarmSound/ と README.txt を用意 (存在すればスキップ)。
        audio.ensureAlarmSoundFolder()

        alarms = storage.load()

        _ = await alarmService.ensureAuthorized()
        authorizationDenied = (alarmService.currentAuthorizationState == .denied)

        // AlarmKit 側と揃える (bootstrap は idempotent、内容未変更なら再登録しない)。
        let report = await alarmService.syncSchedule(with: alarms, forceReregister: false)
        authorizationDenied = authorizationDenied || report.authorizationDenied
        failedAlarmIDs = report.failedIDs
        lastScheduleFailureMessage = report.lastFailureMessage

        // TZ 監視 3 層
        tzWatcher.onTimeZoneChanged = { [weak self] in
            guard let self else { return }
            Task { @MainActor in
                // TZ 変化時は oneShotAt (.fixed(Date)) を再登録すべきなので force = true
                let report = await self.alarmService.syncSchedule(with: self.alarms, forceReregister: true)
                self.failedAlarmIDs = report.failedIDs
                self.lastScheduleFailureMessage = report.lastFailureMessage
            }
        }
        tzWatcher.checkOnLaunch()
        tzWatcher.startObserving()
        // v7: BGTaskSchedulerPermittedIdentifiers が Info.plist に無いため submit() は失敗する。
        // 呼び出し自体は try で catch されるが、無駄なログを避けるためコメントアウト。
        // tzWatcher.scheduleNextBackgroundRefresh()

        // 発火中アラームは scenePhase active の時に checkAlerting() で拾う
        // (AlarmClockApp.swift 側で onChange を仕込んでいる)。
        checkAlerting()

        // 音楽ボタン (OpenAndPlayIntent) 起動時の pending をチェック
        checkPendingPlayback()
    }

    /// AlarmKit 側で .alerting になっているアラームがあれば、対応する AlarmItem を
    /// ringingAlarm に立てる → RingingView が sheet で表示される。
    ///
    /// secondary button を外したので、alerting 検出時に音楽再生も自動的に開始する。
    /// (アプリが開いている / フォアグラウンドに戻った時点で発火。ロック画面のみでは動かない。)
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
            // 音楽ランダム再生を自動開始 (既に再生中なら何もしない)。
            if !audio.isPlaying {
                let count = audio.playRandom(
                    folderRelPath: match.folderRelPath,
                    musicLibraryIDs: match.musicLibraryItemIDs,
                    volume: match.volume,
                    fadeInSeconds: match.fadeInSeconds
                )
                if count == 0 {
                    let folder = match.folderRelPath.map { $0.isEmpty ? "Documents 直下" : $0 } ?? "Documents 直下"
                    transientWarning = "再生できる音源が見つかりませんでした。フォルダ (\(folder)) に対応形式のファイルを配置するか、Apple Music から曲を選択してください。"
                }
            }
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

        // 音楽再生開始 (フォルダの曲 + Apple Music ライブラリの選択曲)
        let count = audio.playRandom(
            folderRelPath: item.folderRelPath,
            musicLibraryIDs: item.musicLibraryItemIDs,
            volume: item.volume,
            fadeInSeconds: item.fadeInSeconds
        )
        ringingAlarm = item

        // 再生対象が 0 なら警告 (フォルダに音源が無い / ライブラリから全部削除された等)。
        if count == 0 {
            let folder = item.folderRelPath.map { $0.isEmpty ? "Documents 直下" : $0 } ?? "Documents 直下"
            transientWarning = "再生できる音源が見つかりませんでした。フォルダ (\(folder)) に対応形式 (flac / mp3 / aac / wav / m4a) のファイルがあるか、Apple Music の選択曲がまだライブラリに残っているか確認してください。"
        }
    }

    // MARK: - CRUD

    func addOrUpdate(_ item: AlarmItem) {
        if let idx = alarms.firstIndex(where: { $0.id == item.id }) {
            alarms[idx] = item
        } else {
            alarms.append(item)
        }
        persistAndSync(forceReregister: true)
    }

    func delete(_ id: UUID) {
        alarms.removeAll { $0.id == id }
        alarmService.cancel(id: id)
        failedAlarmIDs.remove(id)
        persistAndSync(forceReregister: false)
    }

    func toggleEnabled(_ id: UUID, enabled: Bool) {
        guard let idx = alarms.firstIndex(where: { $0.id == id }) else { return }
        alarms[idx].enabled = enabled
        // 無効化なら stop するだけで再登録不要、有効化なら登録が必要
        persistAndSync(forceReregister: enabled)
    }

    private func persistAndSync(forceReregister: Bool) {
        storage.save(alarms)
        Task {
            let report = await alarmService.syncSchedule(with: alarms, forceReregister: forceReregister)
            self.authorizationDenied = report.authorizationDenied || (alarmService.currentAuthorizationState == .denied)
            self.failedAlarmIDs = report.failedIDs
            self.lastScheduleFailureMessage = report.lastFailureMessage
        }
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
            musicLibraryItemIDs: a.musicLibraryItemIDs,
            volume: a.volume,
            fadeInSeconds: a.fadeInSeconds,
            snoozeEnabled: a.snoozeEnabled,
            snoozeMinutes: a.snoozeMinutes
        )
        addOrUpdate(snoozeItem)
        ringingAlarm = nil
    }

    // MARK: - UI 補助

    /// 一過性警告をクリア (UI 側でユーザーが閉じた時)。
    func dismissTransientWarning() {
        transientWarning = nil
    }
}
