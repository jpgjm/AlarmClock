//
//  TimeZoneWatcher.swift
//  AlarmClock
//
//  PDF「3 層補正アーキテクチャ」を実装。`.fixed(Date)` で登録された one-shot アラームが
//  タイムゾーン変更により意図しない時刻に発火するのを防ぐため、以下の 3 段で検知して
//  再スケジュールをかける:
//
//    1. 起動時: 最後に保存した TZ と現在の TZ を比較。異なれば onTimeZoneChanged コール。
//    2. バックグラウンド: BGAppRefreshTask (com.example.alarmclock.tz-recheck)
//       が OS から呼ばれたタイミングで同じ比較を実行。
//    3. 実行中: NSSystemTimeZoneDidChange 通知を購読して即座にコール。
//
//  BGAppRefreshTask の登録は AppDelegate 相当の場所 (AlarmClockApp.init)
//  で BGTaskScheduler に対して行う。
//

import BackgroundTasks
import Combine
import Foundation
import UIKit

@MainActor
final class TimeZoneWatcher {
    static let shared = TimeZoneWatcher()

    static let bgTaskIdentifier = "com.example.alarmclock.tz-recheck"

    /// TZ が変わったと判定したら呼ばれる。呼び側で AlarmService.syncSchedule() を叩く想定。
    var onTimeZoneChanged: (() -> Void)?

    private let storage = AlarmStorage.shared
    private var tzObserver: NSObjectProtocol?

    // MARK: - 起動時チェック (層 1)

    func checkOnLaunch() {
        let current = TimeZone.current.identifier
        let last = storage.lastKnownTimeZoneIdentifier
        storage.lastKnownTimeZoneIdentifier = current
        if let last, last != current {
            onTimeZoneChanged?()
        }
    }

    // MARK: - 実行中通知購読 (層 3)

    func startObserving() {
        stopObserving()
        tzObserver = NotificationCenter.default.addObserver(
            forName: .NSSystemTimeZoneDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = TimeZone.current.identifier
                self.storage.lastKnownTimeZoneIdentifier = current
                self.onTimeZoneChanged?()
            }
        }
    }

    func stopObserving() {
        if let o = tzObserver {
            NotificationCenter.default.removeObserver(o)
            tzObserver = nil
        }
    }

    // MARK: - BGAppRefreshTask (層 2)

    /// アプリ起動時に 1 度だけ呼ぶ。BGTaskScheduler にハンドラを登録する。
    /// `@main App.init()` から呼べるように `nonisolated static` にしている。
    /// 内部で Task { @MainActor in } を使って shared にアクセスする。
    nonisolated static func registerBackgroundTask() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: Self.bgTaskIdentifier,
            using: nil
        ) { task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                Self.shared.handleBackgroundRefresh(task: refreshTask)
            }
        }
    }

    /// 次回の BG リフレッシュを登録 (1 時間後を希望、実際の実行タイミングは OS 判断)。
    func scheduleNextBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date().addingTimeInterval(60 * 60)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            debugPrint("BGTaskScheduler.submit failed: \(error)")
        }
    }

    private func handleBackgroundRefresh(task: BGAppRefreshTask) {
        // 次回もスケジュールし直す (連鎖)
        scheduleNextBackgroundRefresh()

        task.expirationHandler = {
            // 何もしない (軽い処理のみ)
        }

        let current = TimeZone.current.identifier
        let last = storage.lastKnownTimeZoneIdentifier
        storage.lastKnownTimeZoneIdentifier = current
        if let last, last != current {
            onTimeZoneChanged?()
        }
        task.setTaskCompleted(success: true)
    }
}
