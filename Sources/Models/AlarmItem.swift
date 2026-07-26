//
//  AlarmItem.swift
//  AlarmClock
//
//  ユーザーが編集する 1 件分のアラーム設定。
//  AlarmKit の Alarm ID (UUID) と 1:1 対応。
//
//  v12 でシンプル化:
//    - 音楽再生・音量・フェードイン・Apple Music 選択は削除
//    - アラーム音源は「AlarmKit の sound: に直接渡す」経路のみ
//      → customSoundName (指定ファイル) または folderRelPath (フォルダから抽選) を使う
//    - スヌーズは AlarmKit ネイティブ (.countdown behavior) で提供
//
//  スケジュール種別:
//    - .weekly(days): 毎週指定曜日 (曜日繰り返し)  → AlarmKit .relative.weekly
//    - .oneShotAt(date): 特定の日時 1 回のみ  → AlarmKit .fixed(Date)
//        「明後日 7:00」もこれで表現できる (画面上「特定日1回」から選択)
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
    var snoozeEnabled: Bool
    var snoozeMinutes: Int

    /// AlarmKit の `sound:` パラメータに渡すカスタム音源ファイル名。
    /// nil → デフォルトのシステムアラーム音、または folderRelPath がある場合はフォルダ抽選。
    /// 値 → `Library/Sounds/` 配下の指定ファイル名 (拡張子込み、例: "115a...ed7.wav")。
    var customSoundName: String?

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
        snoozeEnabled: Bool = true,
        snoozeMinutes: Int = 5,
        customSoundName: String? = nil
    ) {
        self.id = id
        self.hour = hour
        self.minute = minute
        self.schedule = schedule
        self.enabled = enabled
        self.label = label
        self.folderRelPath = folderRelPath
        self.snoozeEnabled = snoozeEnabled
        self.snoozeMinutes = snoozeMinutes
        self.customSoundName = customSoundName
    }

    // MARK: - Codable (旧バージョン JSON との後方互換)
    // 既存の UserDefaults に保存された旧形式 (musicLibraryItemIDs / volume / fadeInSeconds を
    // 含む) を読めるようにするため、init(from:) を明示実装する。旧フィールドは無視する。

    private enum CodingKeys: String, CodingKey {
        case id, hour, minute, schedule, enabled, label
        case folderRelPath
        case snoozeEnabled, snoozeMinutes
        case customSoundName
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.hour = try c.decode(Int.self, forKey: .hour)
        self.minute = try c.decode(Int.self, forKey: .minute)
        self.schedule = try c.decode(Schedule.self, forKey: .schedule)
        self.enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        self.label = try c.decodeIfPresent(String.self, forKey: .label) ?? ""
        self.folderRelPath = try c.decodeIfPresent(String.self, forKey: .folderRelPath)
        self.snoozeEnabled = try c.decodeIfPresent(Bool.self, forKey: .snoozeEnabled) ?? true
        self.snoozeMinutes = try c.decodeIfPresent(Int.self, forKey: .snoozeMinutes) ?? 5
        self.customSoundName = try c.decodeIfPresent(String.self, forKey: .customSoundName)
        // NOTE: 旧フィールド (musicLibraryItemIDs / volume / fadeInSeconds) は
        // decode しない = 単純に無視される。次に encode するとキーごと消える。
    }

    // MARK: - Convenience

    /// 新規作成時のデフォルト。毎日 07:00・ラベルなし・フォルダは "AlarmSound"・スヌーズ有効。
    static func defaultForNewAlarm() -> AlarmItem {
        return AlarmItem(
            hour: 7,
            minute: 0,
            schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7]),
            label: "",
            folderRelPath: "AlarmSound"
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
