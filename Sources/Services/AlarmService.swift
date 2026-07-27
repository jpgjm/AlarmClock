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
//  v16 でスヌーズを自前実装に変更:
//    - secondaryButton = スヌーズ、secondaryButtonBehavior = .custom
//    - secondaryIntent = SnoozeAndOpenIntent (押下でアプリを開く)
//    - countdownDuration は使わない (常に nil)
//    - 再鳴動は BackgroundAlarmTasks.createSnoozeInstance() が
//      「N 分後の oneShotAt」を持つスヌーズインスタンスとして登録し直す
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

/// スケジュール同期の結果。UI で失敗を可視化するために使う。
struct AlarmSyncResult {
    /// 登録に失敗したアラームの ID 集合。
    var failedIDs: Set<UUID> = []
    /// 直近の失敗の内容 (domain / code 付き)。原因究明の手掛かりにする。
    var lastFailureMessage: String?

    var hasFailure: Bool { !failedIDs.isEmpty }
}

/// AlarmKit の薄いラッパ。
///
/// 【v26】`@MainActor` を外した。
///   App Intent (停止 / スヌーズ) を `openAppWhenRun = false` で動かすため、
///   アプリを起動していない文脈からもこのクラスを使う必要がある。
///
///   保持している状態は `manager` (AlarmManager.shared) だけで、
///   これは let かつ AlarmKit 側で管理されるため、複数スレッドから
///   参照しても問題ない。よって `@unchecked Sendable` を付けて共有可能にする。
final class AlarmService: @unchecked Sendable {
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
    /// - Returns: 登録に失敗したアラームを含む結果。UI での警告表示に使う。
    @discardableResult
    func syncSchedule(with items: [AlarmItem]) async -> AlarmSyncResult {
        var result = AlarmSyncResult()

        let existing = Set(((try? manager.alarms) ?? []).map { $0.id })
        let desiredEnabled = items.filter { $0.enabled }
        let desiredIds = Set(desiredEnabled.map { $0.id })

        // アプリ側から消えた or 無効化されたものを AlarmKit からも削除する。
        //
        // 【重要】ここは stop ではなく cancel を使う。
        //   stop(id:)   = 鳴っているアラートを止めるだけ。登録は AlarmKit に残り続ける。
        //   cancel(id:) = 登録そのものを削除する。(Apple 公式サンプルの unscheduleAlarm と同じ)
        for id in existing where !desiredIds.contains(id) {
            try? manager.cancel(id: id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
            EventLog.log(.cancel, alarmID: id, message: "アプリ側に無い/無効なため登録解除")
        }

        // 【v22】差分同期に変更した。
        //
        // v21 までは有効な全アラームを毎回 schedule() し直していた。その際
        // schedule() の冒頭で同じ ID を cancel していたが、cancel は AlarmKit 内部で
        // 非同期に処理されるため、直後に同じ ID で schedule すると競合して
        // com.apple.AlarmKit.Alarm error 0 で失敗していた。
        // (診断画面で「登録済 / scheduled」なのにエラーバナーが出る、
        //  purge しても取り残しが消えない、といった症状の原因)
        //
        // そこで「既に AlarmKit に登録されている ID は触らない」ようにする。
        // AlarmKit の登録はアプリを起動しなくても永続するので、これで問題ない。
        //
        // ランダム抽選のやり直しは AlarmAppState 側が担当する。
        // アラームを停止した時などに ID を振り直して登録し直すため、
        // cancel と schedule の ID が別になり競合しない。
        for item in desiredEnabled {
            if existing.contains(item.id) {
                // 既に登録済み → そのまま活かす (再登録すると競合するため)
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "登録済みのためスキップ (\(String(format: "%02d:%02d", item.hour, item.minute)))")
                continue
            }

            // 【v27】発火時刻が既に過ぎている一回限りアラームは登録しない。
            //
            // AlarmKit は `.fixed(Date)` に過去の日時を渡すと
            // com.apple.AlarmKit.Alarm error 0 で拒否する。
            // 鳴り終わったスヌーズがアプリ側の一覧に残っていると、
            // 編集や新規作成のたびにこの無駄な登録が試みられ、
            // 「アラームを登録できませんでした」の警告が出てしまう。
            if case .oneShotAt(let fireDate) = item.schedule, fireDate < Date() {
                let f = DateFormatter()
                f.locale = Locale(identifier: "ja_JP")
                f.dateFormat = "M/d H:mm"
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "発火時刻 (\(f.string(from: fireDate))) が過去のため登録せず")
                continue
            }

            do {
                try await schedule(item)
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "新規登録 \(String(format: "%02d:%02d", item.hour, item.minute)) / \(item.scheduleLabel())")
            } catch {
                let ns = error as NSError
                let msg = "\(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]"
                debugPrint("AlarmKit schedule failed for \(item.id): \(msg)")
                EventLog.log(.scheduleNG, alarmID: item.id, message: msg)
                result.failedIDs.insert(item.id)
                result.lastFailureMessage = msg
            }
        }

        return result
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
    ///   snoozeEnabled が true の場合、secondaryButton にスヌーズを置き
    ///   .custom behavior + SnoozeAndOpenIntent を割り当てる。
    ///   押下すると (アプリは開かずに) BackgroundAlarmTasks.createSnoozeInstance() が
    ///   「N 分後に鳴る一時アラーム (スヌーズインスタンス)」を登録し直す。
    ///   その際に音源の再抽選も走るため、スヌーズのたびに別の曲になる。
    func schedule(_ item: AlarmItem) async throws {
        // 【v22】ここで cancel を呼ばない。
        //
        // v18〜v21 では「編集内容を確実に反映させる」ため、schedule の直前に
        // 同じ ID を stop / cancel していた。しかし cancel は AlarmKit 内部で
        // 非同期に処理されるため、直後の schedule と競合して
        // com.apple.AlarmKit.Alarm error 0 を引き起こしていた。
        //
        // 編集時の反映は AlarmAppState が ID を振り直す (replacingID) ことで
        // 担保している。新しい ID には既存登録が無いので、そもそも消す必要がない。
        // 古い ID の登録は syncSchedule の削除ループが片付ける。

        let alarmSchedule = Self.buildAlarmKitSchedule(from: item)

        let stopButton = AlarmButton(
            text: "停止",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )

        // スヌーズ有効時のみ secondary button を追加 (.custom behavior)
        //
        // v16 で .countdown から .custom に変更した。
        // .countdown は AlarmKit が内部で再鳴動を処理するためアプリが起動せず、
        //   - スヌーズ再鳴動で同じ曲が鳴り続ける
        //   - 次回アラームの抽選も走らない
        // という制約があった。.custom + SnoozeAndOpenIntent なら押下時にアプリが開き、
        // BackgroundAlarmTasks.createSnoozeInstance() が N 分後の一時アラームを作る。
        let alertPresentation: AlarmPresentation.Alert
        let secondaryIntent: SnoozeAndOpenIntent?

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
                secondaryButtonBehavior: .custom
            )
            secondaryIntent = SnoozeAndOpenIntent(alarmID: item.id.uuidString)
        } else {
            alertPresentation = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
                stopButton: stopButton
            )
            secondaryIntent = nil
        }

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes<AlarmClockMetadata>(
            presentation: presentation,
            tintColor: .orange
        )

        // 音源の決定 (v14 で 3 モード対応)
        //   .defaultSound → .default
        //   .fixed → customSoundName を .named() で直接
        //   .random → prepareAlarmSound() で複数ソースから抽選
        let soundConfig: AlertConfiguration.AlertSound
        switch item.soundSourceMode {
        case .defaultSound:
            soundConfig = .default

        case .fixed:
            if let name = item.customSoundName, !name.isEmpty {
                soundConfig = .named(name)
                EventLog.log(.sound, alarmID: item.id, message: "固定音源: \(name)")
            } else {
                soundConfig = .default  // フォールバック (未選択時)
                EventLog.log(.sound, alarmID: item.id, message: "固定音源が未選択のためシステム標準")
            }

        case .random:
            if let prepared = await SoundLibraryService.shared.prepareAlarmSound(
                alarmID: item.id,
                // スヌーズインスタンスは元アラームと抽選履歴を共有する。
                // これにより「元 → スヌーズ 1 → スヌーズ 2」で同じ曲が連続しにくくなる。
                historyKeyID: item.snoozeSourceID,
                useFolder: item.randomSourceUseFolder,
                folderRelPath: item.folderRelPath,
                libraryFileNames: item.randomSourceLibraryFileNames
            ) {
                soundConfig = .named(prepared.alarmKitName)
                EventLog.log(.sound, alarmID: item.id,
                             message: "抽選: \(prepared.sourceName) [.\(prepared.deliveredExtension)] (候補 \(prepared.candidateCount) 曲中、履歴により \(prepared.excludedCount) 曲を除外)")
            } else {
                soundConfig = .default  // 抽選対象がない時のフォールバック
                EventLog.log(.sound, alarmID: item.id, message: "抽選候補なしのためシステム標準")
            }
        }

        let configuration = AlarmManager.AlarmConfiguration<AlarmClockMetadata>(
            // .custom スヌーズでは AlarmKit のカウントダウンを使わないので常に nil
            countdownDuration: nil,
            schedule: alarmSchedule,
            attributes: attributes,
            // 停止ボタンにアプリを開く Intent を割り当てる。
            // 押下時にアプリが起動して bootstrap → syncSchedule → prepareAlarmSound
            // が走り、次回のアラーム音が再抽選される。
            stopIntent: StopAndOpenIntent(alarmID: item.id.uuidString),
            secondaryIntent: secondaryIntent,
            sound: soundConfig
        )

        _ = try await manager.schedule(id: item.id, configuration: configuration)
    }

    /// 指定アラームの登録を AlarmKit から削除する。
    /// stop ではなく cancel を使うのが正しい (stop は鳴っているアラートを止めるだけ)。
    func cancel(id: UUID) {
        try? manager.cancel(id: id)
        SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
        EventLog.log(.cancel, alarmID: id, message: "登録解除")
    }

    // MARK: - 診断用

    /// AlarmKit に現在登録されているアラームの ID → state を文字列で返す。
    /// DiagnosticsView が「本当に登録されているか」を可視化するために使う。
    func currentRegisteredAlarmStatesText() -> [UUID: String] {
        let current = (try? manager.alarms) ?? []
        var out: [UUID: String] = [:]
        for a in current {
            out[a.id] = String(describing: a.state)
        }
        return out
    }

    /// 認可状態を文字列で返す (診断表示用)。
    func authorizationStateText() -> String {
        switch manager.authorizationState {
        case .authorized:    return "authorized (許可済み)"
        case .denied:        return "denied (拒否)"
        case .notDetermined: return "notDetermined (未確認)"
        @unknown default:    return "unknown"
        }
    }

    /// アプリ側に存在しない「取り残された登録」を AlarmKit から一掃する。
    ///
    /// v20 まで削除に stop を使っていた影響で、登録が消えずに溜まっている
    /// 環境があるための救済措置。診断画面から手動で実行できるようにしている。
    ///
    /// - Parameter keepingIDs: 残しておく (= アプリ側に存在する) アラーム ID
    /// - Returns: 削除した件数
    @discardableResult
    func purgeOrphanRegistrations(keepingIDs: Set<UUID>) -> Int {
        let current = (try? manager.alarms) ?? []
        var removed = 0
        for a in current where !keepingIDs.contains(a.id) {
            try? manager.cancel(id: a.id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: a.id)
            EventLog.log(.purge, alarmID: a.id, message: "取り残された登録を削除 (state: \(String(describing: a.state)))")
            removed += 1
        }
        debugPrint("[Purge] removed \(removed) orphan registration(s)")
        return removed
    }

    /// AlarmKit に登録されているアラームをすべて削除する。
    func cancelAll() {
        let current = (try? manager.alarms) ?? []
        for a in current {
            try? manager.cancel(id: a.id)
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
