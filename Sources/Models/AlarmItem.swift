//
//  AlarmItem.swift
//  AlarmClock
//
//  ユーザーが編集する 1 件分のアラーム設定。
//  AlarmKit の Alarm ID (UUID) と 1:1 対応。ユーザーの好み設定 (音量/フェード/フォルダ等)
//  はアプリ側の UserDefaults に保存し、AlarmKit にはスケジュール情報だけ登録する。
//
//  スケジュール種別:
//    - .weekly(days): 毎週指定曜日 (曜日繰り返し)  → AlarmKit .relative.weekly
//    - .oneShotAt(date): 特定の日時 1 回のみ  → AlarmKit .fixed(Date)
//        「明後日 7:00」もこれで表現する (デフォルト新規作成時に「明後日」候補)
//

import Foundation

struct AlarmItem: Codable, Identifiable, Equatable {
    let id: UUID
    var hour: Int
    var minute: Int
    var schedule: Schedule
    var enabled: Bool
    var label: String
    var folderRelPath: String?     // Documents ルートからの相対パス、nil = 全体
    var volume: Double             // 0.0-1.0
    var fadeInSeconds: Int         // 0 = 無効
    var snoozeEnabled: Bool
    var snoozeMinutes: Int

    enum Schedule: Codable, Equatable {
        /// 毎週の指定曜日繰り返し。空セットは不正 (init 時にガード)。
        /// 1=月 ... 7=日 (DateTime 互換)。
        case weekly(days: Set<Int>)

        /// 特定日時に 1 回のみ (UTC absolute)。TZ 変更時は再スケジュール推奨。
        case oneShotAt(date: Date)
    }

    init(
        id: UUID = UUID(),
        hour: Int,
        minute: Int,
        schedule: Schedule,
        enabled: Bool = true,
        label: String = "",
        folderRelPath: String? = nil,
        volume: Double = 0.7,
        fadeInSeconds: Int = 20,
        snoozeEnabled: Bool = true,
        snoozeMinutes: Int = 5
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.schedule = schedule
        self.enabled = enabled
        self.label = label
        self.folderRelPath = folderRelPath
        self.volume = volume
        self.fadeInSeconds = fadeInSeconds
        self.snoozeEnabled = snoozeEnabled
        self.snoozeMinutes = snoozeMinutes
    }

    // MARK: - Convenience

    /// 新規作成時のデフォルト。明後日 07:00・スヌーズ有効。
    /// PDF「あさってアラーム」の主題を踏まえて「明後日」プリセットを用意。
    static func defaultDayAfterTomorrow(now: Date = Date(),
                                        calendar: Calendar = .current) -> AlarmItem {
        let dayAfterTomorrow = calendar.date(byAdding: .day, value: 2, to: now) ?? now
        var comps = calendar.dateComponents([.year, .month, .day], from: dayAfterTomorrow)
        comps.hour = 7
        comps.minute = 0
        let date = calendar.date(from: comps) ?? now
        return AlarmItem(
            hour: 7,
            minute: 0,
            schedule: .oneShotAt(date: date),
            label: "明後日の起床"
        )
    }

    /// UI 表示用のスケジュール要約。
    func scheduleLabel(calendar: Calendar = .current) -> String {
        switch schedule {
        case .weekly(let days):
            return Self.weekdaysDisplayLabel(days: days)
        case .oneShotAt(let date):
            let f = DateFormatter()
            f.locale = Locale(identifier: "ja_JP")
            f.dateFormat = "M月d日(E)"
            return "\(f.string(from: date)) のみ"
        }
    }

    static func weekdaysDisplayLabel(days: Set<Int>) -> String {
        let names = ["月", "火", "水", "木", "金", "土", "日"]
        if days.count == 7 { return "毎日" }
        if days == [1, 2, 3, 4, 5] { return "平日" }
        if days == [6, 7] { return "週末" }
        let sorted = days.sorted()
        return sorted.map { names[$0 - 1] }.joined(separator: "・")
    }
}
