//
//  AlarmService.swift
//  AlarmClock
//
//  AlarmKit の薄いラッパ。
//    - 権限リクエスト (`AlarmManager.shared.requestAuthorization()`)
//    - AlarmItem.Schedule → AlarmKit の Alarm.Schedule への変換
//    - AlarmConfiguration の組み立て
//    - スケジュール / 全削除 / 全再登録
//
//  v12 でシンプル化:
//    - 「音楽で起きる」secondary button + OpenAndPlayIntent を廃止
//    - スヌーズは AlarmKit ネイティブ (.countdown behavior) で提供
//        secondaryButton = スヌーズ、secondaryButtonBehavior = .countdown
//        countdownDuration.postAlert = snoozeMinutes × 60 秒
//    - snoozeEnabled が false の場合は secondaryButton なし (停止のみ)
//    - stopIntent は StopAndOpenIntent (押下時にアプリを開いて次回抽選) のまま維持
//    - sound: パラメータは customSoundName または フォルダ抽選 or .default
//

import AlarmKit
import ActivityKit
import AppIntents
import Foundation
import SwiftUI

/// カスタムメタデータを AlarmAttributes に付ける必要がある (AlarmKit の要件)。
/// Countdown Presentation を使わないので基本空でよいが、Codable 実装の型が必要。
struct AlarmClockMetadata: AlarmMetadata {}

@MainActor
final class AlarmService {
    static let shared = AlarmService()

    private let manager = AlarmManager.shared

    // MARK: - 権限

    /// 未リクエストなら権限ダイアログを出す。既に決定済みならその状態を返す。
    /// - Returns: 認可されているかどうか
    func ensureAuthorized() async -> Bool {
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let state = try await manager.requestAuthorization()
                return state == .authorized
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - スケジュール

    /// アプリ側の AlarmItem 一覧を AlarmKit にまるごと反映する。
    /// 既存の AlarmKit 登録は「アプリで無効化された/削除された分」だけ解除する。
    ///
    /// schedule() 内で毎回 prepared 音源を作り直すため、この呼び出しは
    /// アプリ起動のたびに翌回のアラーム曲を再抽選する役割も担う。
    func syncSchedule(with items: [AlarmItem]) async {
        let existing = ((try? manager.alarms) ?? []).map { $0.id }
        let desiredEnabled = items.filter { $0.enabled }
        let desiredIds = Set(desiredEnabled.map { $0.id })

        // 消えた or 無効化されたものを stop (stop は 同期 throws) + prepared 音源も掃除
        for id in existing where !desiredIds.contains(id) {
            try? manager.stop(id: id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
        }

        // 有効なアラームを (idempotent に) 登録。
        // schedule() の中で prepared 音源を毎回作り直すので、これが再抽選の起点になる。
        for item in desiredEnabled {
            do {
                try await schedule(item)
            } catch {
                debugPrint("AlarmKit schedule failed for \(item.id): \(error)")
            }
        }
    }

    /// 1件を AlarmKit に登録。既存 ID があれば内部で置き換わる想定 (再登録 = 更新)。
    /// AlarmManager.schedule は `async throws -> Alarm`、
    /// AlarmManager.stop は同期 throws。
    ///
    /// カスタムサウンドの優先順位:
    ///   1. customSoundName が指定されていれば、それを直接再生
    ///   2. なければ folderRelPath (または Documents 直下) から 1 曲ランダム抽選して直接再生
    ///   3. 抽選対象が無ければ .default (システムアラーム音)
    ///
    /// スヌーズ:
    ///   snoozeEnabled が true の場合、AlarmKit ネイティブのスヌーズを有効化する。
    ///   .countdown behavior + countdownDuration.postAlert に snoozeMinutes 分を設定。
    ///   ユーザーがアラート画面で「スヌーズ」を押すと、指定分後に自動で再鳴動する。
    func schedule(_ item: AlarmItem) async throws {
        let alarmSchedule = Self.buildAlarmKitSchedule(from: item)

        let stopButton = AlarmButton(
            text: "停止",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )

        // スヌーズ有効時のみ secondary button を追加 (.countdown behavior)
        let alertPresentation: AlarmPresentation.Alert
        let countdownDuration: Alarm.CountdownDuration?

        if item.snoozeEnabled {
            let snoozeButton = AlarmButton(
                text: "スヌーズ",
                textColor: .white,
                systemImageName: "moon.zzz.fill"
            )
            alertPresentation = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
                stopButton: stopButton,
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: .countdown
            )
            countdownDuration = Alarm.CountdownDuration(
                preAlert: nil,
                postAlert: TimeInterval(item.snoozeMinutes * 60)
            )
        } else {
            alertPresentation = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
                stopButton: stopButton
            )
            countdownDuration = nil
        }

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes<AlarmClockMetadata>(
            presentation: presentation,
            tintColor: .orange
        )

        // 音源の決定
        let soundConfig: AlertConfiguration.AlertSound
        if let soundName = item.customSoundName, !soundName.isEmpty {
            soundConfig = .named(soundName)
        } else if let preparedName = SoundLibraryService.shared.prepareAlarmSound(
            alarmID: item.id,
            folderRelPath: item.folderRelPath
        ) {
            soundConfig = .named(preparedName)
        } else {
            soundConfig = .default
        }

        let configuration = AlarmManager.AlarmConfiguration<AlarmClockMetadata>(
            countdownDuration: countdownDuration,
            schedule: alarmSchedule,
            attributes: attributes,
            // 停止ボタンにアプリを開く Intent を割り当てる。
            // 押下時にアプリが起動して bootstrap → syncSchedule → prepareAlarmSound
            // が走り、次回のアラーム音が再抽選される。
            stopIntent: StopAndOpenIntent(alarmID: item.id.uuidString),
            secondaryIntent: nil,
            sound: soundConfig
        )

        _ = try await manager.schedule(id: item.id, configuration: configuration)
    }

    func cancel(id: UUID) {
        try? manager.stop(id: id)
        SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
    }

    func cancelAll() {
        let current = (try? manager.alarms) ?? []
        for a in current {
            try? manager.stop(id: a.id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: a.id)
        }
    }

    // MARK: - 変換

    /// アプリの Schedule 表現 → AlarmKit の Alarm.Schedule。
    ///
    /// - .weekly(days): AlarmKit `.relative` + `.weekly([Locale.Weekday])`
    /// - .oneShotAt(date): AlarmKit `.fixed(Date)`  (UTC 絶対時刻)
    private static func buildAlarmKitSchedule(from item: AlarmItem) -> Alarm.Schedule {
        switch item.schedule {
        case .weekly(let days):
            let time = Alarm.Schedule.Relative.Time(
                hour: item.hour,
                minute: item.minute
            )
            // ISO 曜日 (1=月...7=日) → Locale.Weekday
            let weekdays: [Locale.Weekday] = days.compactMap { d in
                switch d {
                case 1: return .monday
                case 2: return .tuesday
                case 3: return .wednesday
                case 4: return .thursday
                case 5: return .friday
                case 6: return .saturday
                case 7: return .sunday
                default: return nil
                }
            }
            let recurrence: Alarm.Schedule.Relative.Recurrence = weekdays.isEmpty
                ? .never
                : .weekly(weekdays)
            return .relative(
                Alarm.Schedule.Relative(time: time, repeats: recurrence)
            )

        case .oneShotAt(let date):
            // AlarmKit `.fixed(Date)` は UTC 絶対時刻として保存される。
            // TimeZoneWatcher が TZ 変更を検知したら再スケジュールをかける。
            return .fixed(date)
        }
    }
}
