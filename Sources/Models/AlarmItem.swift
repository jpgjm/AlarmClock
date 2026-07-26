//
//  AlarmItem.swift
//  AlarmClock
//
//  ユーザーが編集する 1 件分のアラーム設定。
//  AlarmKit の Alarm ID (UUID) と 1:1 対応。
//
//  v14 で音源指定を 3 モード化:
//    - .defaultSound: iOS 標準のアラーム音
//    - .fixed: customSoundName で 1 曲固定
//    - .random: 複数ソース (フォルダ + Library/Sounds の選択曲) からランダム抽選
//
//  スケジュール種別:
//    - .weekly(days): 毎週指定曜日  → AlarmKit .relative.weekly
//    - .oneShotAt(date): 特定日時 1 回のみ  → AlarmKit .fixed(Date)
//

import Foundation

/// 音源の選び方 (アラーム発火時にどう鳴らすか)。
enum SoundSourceMode: String, Codable {
    /// iOS 標準のアラーム音を鳴らす。
    case defaultSound
    /// customSoundName で 1 つ選んだ音源を固定的に鳴らす。
    case fixed
    /// 複数ソース (フォルダ + Library/Sounds の選択曲) からランダムに 1 つ抽選して鳴らす。
    /// - フォルダ抽選対象: randomSourceUseFolder && folderRelPath 配下
    /// - Library/Sounds 抽選対象: randomSourceLibraryFileNames に列挙されたファイル
    case random
}

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

    // MARK: - 音源

    /// 音源選択モード。
    var soundSourceMode: SoundSourceMode

    /// .fixed モード時に使う音源ファイル名 (Library/Sounds/{...})。
    /// AlarmKit の `.named(fileName)` にそのまま渡す文字列。
    var customSoundName: String?

    /// .random モード時、フォルダを抽選対象に含めるかどうか。
    /// true の時は folderRelPath 配下 (Documents 内) から候補が選ばれる。
    var randomSourceUseFolder: Bool

    /// .random モード時、抽選対象に含める Library/Sounds のファイル名集合。
    /// 各エントリは `.named()` に渡せる形式 (拡張子込み、例 "abc123.m4a")。
    var randomSourceLibraryFileNames: Set<String>

    // MARK: - Schedule enum

    enum Schedule: Codable, Equatable {
        case weekly(days: Set<Int>)
        case oneShotAt(date: Date)
    }

    // MARK: - Init

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
        soundSourceMode: SoundSourceMode = .defaultSound,
        customSoundName: String? = nil,
        randomSourceUseFolder: Bool = false,
        randomSourceLibraryFileNames: Set<String> = []
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
        self.soundSourceMode = soundSourceMode
        self.customSoundName = customSoundName
        self.randomSourceUseFolder = randomSourceUseFolder
        self.randomSourceLibraryFileNames = randomSourceLibraryFileNames
    }

    // MARK: - Codable (旧バージョン JSON との後方互換)
    //
    // 旧フィールド (musicLibraryItemIDs / volume / fadeInSeconds) は無視。
    // 旧フォーマット (soundSourceMode 未存在) からのマイグレーション:
    //   - customSoundName != nil → .fixed
    //   - customSoundName == nil && folderRelPath != nil → .random (フォルダのみ ON)
    //   - どちらも nil → .defaultSound

    private enum CodingKeys: String, CodingKey {
        case id, hour, minute, schedule, enabled, label
        case folderRelPath
        case snoozeEnabled, snoozeMinutes
        case customSoundName
        case soundSourceMode
        case randomSourceUseFolder
        case randomSourceLibraryFileNames
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

        // v14 新フィールドのマイグレーション
        if let mode = try c.decodeIfPresent(SoundSourceMode.self, forKey: .soundSourceMode) {
            self.soundSourceMode = mode
        } else if self.customSoundName != nil {
            self.soundSourceMode = .fixed
        } else if self.folderRelPath != nil {
            // 旧バージョン: folderRelPath が指定されていた = フォルダから抽選が有効
            self.soundSourceMode = .random
        } else {
            self.soundSourceMode = .defaultSound
        }

        self.randomSourceUseFolder = try c.decodeIfPresent(Bool.self, forKey: .randomSourceUseFolder)
            ?? (self.folderRelPath != nil)  // 旧データで folderRelPath があれば ON 継承

        self.randomSourceLibraryFileNames = try c.decodeIfPresent(Set<String>.self, forKey: .randomSourceLibraryFileNames)
            ?? []
    }

    // MARK: - Convenience

    /// 新規作成時のデフォルト。
    ///   - 時刻: **現在時刻** (v14 まで 07:00 固定だったのを変更)
    ///   - 曜日: 毎日
    ///   - 音源: フォルダ抽選モード (AlarmSound から)
    ///   - スヌーズ: 有効 (5 分)
    ///
    /// 現在時刻を初期値にすることで、「今から数分後にテストしたい」「起きたい時刻の近くを
    /// 起点に微調整したい」といった実際の使い方に合わせる。
    static func defaultForNewAlarm(now: Date = Date(), calendar: Calendar = .current) -> AlarmItem {
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        return AlarmItem(
            hour: comps.hour ?? 7,
            minute: comps.minute ?? 0,
            schedule: .weekly(days: [1, 2, 3, 4, 5, 6, 7]),
            label: "",
            folderRelPath: "AlarmSound",
            soundSourceMode: .random,
            customSoundName: nil,
            randomSourceUseFolder: true,
            randomSourceLibraryFileNames: []
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
