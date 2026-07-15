//
//  AlarmService.swift
//  AlarmClock
//
//  AlarmKit の薄いラッパ。
//    - 権限リクエスト (`AlarmManager.shared.requestAuthorization()`)
//    - AlarmItem.Schedule → AlarmKit の Alarm.Schedule への変換
//    - AlarmConfiguration の組み立て (Alert 用の secondary button = OpenAndPlayIntent)
//    - スケジュール / 全削除 / 全再登録
//
//  スヌーズは AlarmKit の `.snooze` ボタン挙動を使うのではなく、二次アクションを
//  「音楽で起きる (OpenAndPlayIntent)」に振っている。スヌーズはアプリ内画面 (RingingView)
//  にボタンとして持ち、押下時に「N 分後の oneShotAt」でもう 1 件登録する。
//

import AlarmKit
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
    func syncSchedule(with items: [AlarmItem]) async {
        // 現状の登録一覧
        let existing = manager.alarms.map { $0.id }
        let desiredEnabled = items.filter { $0.enabled }
        let desiredIds = Set(desiredEnabled.map { $0.id })

        // 消えた or 無効化されたものを stop
        for id in existing where !desiredIds.contains(id) {
            try? await manager.cancel(id: id)
        }

        // 有効なアラームを (idempotent に) 登録
        for item in desiredEnabled {
            do {
                try await schedule(item)
            } catch {
                debugPrint("AlarmKit schedule failed for \(item.id): \(error)")
            }
        }
    }

    /// 1件を AlarmKit に登録。既存 ID があれば内部で置き換わる想定 (再登録 = 更新)。
    func schedule(_ item: AlarmItem) async throws {
        let alarmSchedule = Self.buildAlarmKitSchedule(from: item)

        let stopButton = AlarmButton(
            text: "止める",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )
        let musicButton = AlarmButton(
            text: "音楽で起きる",
            textColor: .white,
            systemImageName: "music.note"
        )

        let alertPresentation = AlarmPresentation.Alert(
            title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
            stopButton: stopButton,
            secondaryButton: musicButton,
            secondaryButtonBehavior: .custom
        )
        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes<AlarmClockMetadata>(
            presentation: presentation,
            tintColor: .orange
        )

        let configuration = AlarmManager.AlarmConfiguration<AlarmClockMetadata>(
            countdownDuration: nil,
            schedule: alarmSchedule,
            attributes: attributes,
            stopIntent: nil,
            secondaryIntent: OpenAndPlayIntent(alarmID: item.id.uuidString)
        )

        try await manager.schedule(id: item.id, configuration: configuration)
    }

    func cancel(id: UUID) async {
        try? await manager.cancel(id: id)
    }

    func cancelAll() async {
        for a in manager.alarms {
            try? await manager.cancel(id: a.id)
        }
    }

    // MARK: - 変換

    /// アプリの Schedule 表現 → AlarmKit の Alarm.Schedule。
    ///
    /// - .weekly(days): AlarmKit `.relative` + `.weekly([Locale.Weekday])`
    /// - .oneShotAt(date): AlarmKit `.fixed(Date)`  (PDF 参照: UTC 絶対時刻)
    private static func buildAlarmKitSchedule(from item: AlarmItem) -> Alarm.Schedule {
        switch item.schedule {
        case .weekly(let days):
            let time = Alarm.Schedule.Relative.Time(
                hour: item.hour,
                minute: item.minute
            )
            let weekdays = days.compactMap { Locale.Weekday.fromIsoWeekday($0) }
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

// MARK: - Locale.Weekday 変換

private extension Locale.Weekday {
    /// 1=月 ... 7=日 の ISO 曜日番号を Locale.Weekday に変換。
    static func fromIsoWeekday(_ n: Int) -> Locale.Weekday? {
        switch n {
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
}
