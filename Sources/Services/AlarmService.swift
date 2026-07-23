//
//  AlarmService.swift
//  AlarmClock
//
//  AlarmKit の薄いラッパ。
//    - 権限リクエスト (`AlarmManager.shared.requestAuthorization()`)
//    - AlarmItem.Schedule → AlarmKit の Alarm.Schedule への変換
//    - AlarmConfiguration の組み立て (Alert 用の secondary button = OpenAndPlayIntent)
//    - スケジュール / 全削除 / 全再登録 (idempotent)
//
//  重要: syncSchedule() は
//    - 既に AlarmKit 側に登録済みで .scheduled 状態
//    - かつアプリ側 AlarmItem の内容 (時刻/曜日/ラベル等) が前回登録時から変わっていない
//    アラームは、再登録をスキップする。
//    これがないと起動のたびに全アラームが schedule() され直され、
//    「1 回目は鳴るが 2 回目以降鳴らない」問題を引き起こす。
//

import AlarmKit
import AppIntents
import Foundation
import SwiftUI

/// AlarmKit の AlarmAttributes に付ける空メタデータ。
/// Apple 公式サンプルの CookingData 相当だが、こちらは特に情報を持たない。
/// 空 struct でも AlarmMetadata (Codable) 準拠なので schedule() には渡せる。
struct AlarmClockMetadata: AlarmMetadata {}

/// スケジュール結果 (AlarmAppState にフィードバックして UI 警告に使う)。
struct AlarmScheduleReport {
    /// 認可状態が拒否 (.denied) だった場合 true。
    var authorizationDenied: Bool = false
    /// スケジュールに失敗したアラーム ID の集合。
    var failedIDs: Set<UUID> = []
    /// 直近のスケジュール失敗のエラー文言 (デバッグ用)。UI 警告に載せる。
    var lastFailureMessage: String?
}

@MainActor
final class AlarmService {
    static let shared = AlarmService()

    private let manager = AlarmManager.shared

    /// AlarmItem.id → 前回登録時のフィンガープリント。
    /// アプリ側の変更検知に使う (時刻・曜日・ラベル・音量・スヌーズ設定など)。
    private var lastRegisteredFingerprints: [UUID: String] = [:]

    // MARK: - 権限

    var currentAuthorizationState: AlarmManager.AuthorizationState {
        manager.authorizationState
    }

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
    ///
    /// - Parameters:
    ///   - items: アプリ側の全アラーム一覧
    ///   - forceReregister: true なら既に .scheduled 状態のアラームも強制的に再登録する。
    ///     編集後 (persistAndSync) など、内容が確実に変わった時のみ true にする。
    ///     bootstrap / TZ 変更時は false で良い (未変更なら再登録スキップ)。
    ///
    /// - Returns: 認可状態や失敗アラームを含むレポート。UI 警告に使う。
    @discardableResult
    func syncSchedule(with items: [AlarmItem], forceReregister: Bool = false) async -> AlarmScheduleReport {
        var report = AlarmScheduleReport()

        // 認可状態
        if manager.authorizationState == .denied {
            report.authorizationDenied = true
        }

        let existingAlarms = (try? manager.alarms) ?? []
        let existingByID: [UUID: Alarm] = Dictionary(uniqueKeysWithValues: existingAlarms.map { ($0.id, $0) })
        let desiredEnabled = items.filter { $0.enabled }
        let desiredIds = Set(desiredEnabled.map { $0.id })

        // 消えた or 無効化されたものを stop
        for existing in existingAlarms where !desiredIds.contains(existing.id) {
            try? manager.stop(id: existing.id)
            lastRegisteredFingerprints.removeValue(forKey: existing.id)
        }

        // 有効なアラームを登録 (原則 idempotent)。
        for item in desiredEnabled {
            let fp = item.scheduleFingerprint

            if !forceReregister,
               let existing = existingByID[item.id],
               existing.state == .scheduled,
               lastRegisteredFingerprints[item.id] == fp {
                continue
            }

            do {
                try await schedule(item)
                lastRegisteredFingerprints[item.id] = fp
            } catch {
                // AlarmKit エラーはドメイン/コード付きで nsError 経由でも取れる。
                // ユーザーに何が起きたか可視化するため、代表的な情報を全部拾って詰める。
                let ns = error as NSError
                let msg = "\(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]"
                debugPrint("AlarmKit schedule failed for \(item.id): \(msg)")
                report.failedIDs.insert(item.id)
                report.lastFailureMessage = msg
                lastRegisteredFingerprints.removeValue(forKey: item.id)
            }
        }

        return report
    }

    /// 1件を AlarmKit に登録。
    ///
    /// Apple 公式サンプル `SchedulingAnAlarmWithAlarmKit` の `scheduleAlertOnlyExample()` に
    /// 準拠した最小構成:
    ///   - `AlarmAttributes<Metadata>(presentation:tintColor:)` (metadata 引数省略の init を使用)
    ///   - `AlarmManager.AlarmConfiguration(schedule:attributes:)` (schedule + attributes のみ)
    ///   - Alert は stopButton のみ (secondaryButton は動作確認後に段階追加)
    ///
    /// これで schedule() が成功したら、次段で `stopIntent:` と `secondaryIntent:` を
    /// 追加して「音楽で起きる」ボタンを復活させる (Apple サンプルの scheduleCustomButtonAlertExample 参照)。
    func schedule(_ item: AlarmItem) async throws {
        let alarmSchedule = Self.buildAlarmKitSchedule(from: item)

        // Apple 公式サンプルの `AlarmButton.stopButton` に合わせる (systemImageName = "stop.circle")。
        let stopButton = AlarmButton(
            text: "止める",
            textColor: .white,
            systemImageName: "stop.circle"
        )

        // title は LocalizedStringResource。動的値の埋め込みは string interpolation で。
        // これは `LocalizedStringResource(stringLiteral:)` で作るより安全。
        let title: LocalizedStringResource = "\(item.label.isEmpty ? "アラーム" : item.label)"
        let alertContent = AlarmPresentation.Alert(
            title: title,
            stopButton: stopButton
        )

        // Apple 公式 scheduleAlertOnlyExample() と同じ形。metadata: は渡さない。
        let attributes = AlarmAttributes<AlarmClockMetadata>(
            presentation: AlarmPresentation(alert: alertContent),
            tintColor: .orange
        )

        // 公式準拠: schedule と attributes のみ。
        let alarmConfiguration = AlarmManager.AlarmConfiguration(
            schedule: alarmSchedule,
            attributes: attributes
        )

        _ = try await manager.schedule(id: item.id, configuration: alarmConfiguration)
    }

    func cancel(id: UUID) {
        try? manager.stop(id: id)
        lastRegisteredFingerprints.removeValue(forKey: id)
    }

    func cancelAll() {
        let current = (try? manager.alarms) ?? []
        for a in current {
            try? manager.stop(id: a.id)
        }
        lastRegisteredFingerprints.removeAll()
    }

    /// 現在 AlarmKit に登録されているアラーム ID + 状態のスナップショット。
    /// UI で "システムに正しく登録されているか" を確認するために使う。
    func currentRegisteredAlarmStates() -> [UUID: Alarm.State] {
        let current = (try? manager.alarms) ?? []
        var out: [UUID: Alarm.State] = [:]
        for a in current { out[a.id] = a.state }
        return out
    }

    // MARK: - 変換

    /// アプリの Schedule 表現 → AlarmKit の Alarm.Schedule。
    private static func buildAlarmKitSchedule(from item: AlarmItem) -> Alarm.Schedule {
        switch item.schedule {
        case .weekly(let days):
            let time = Alarm.Schedule.Relative.Time(
                hour: item.hour,
                minute: item.minute
            )
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
            return .fixed(date)
        }
    }
}
