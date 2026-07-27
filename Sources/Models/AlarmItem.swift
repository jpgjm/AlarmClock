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

    // MARK: - スヌーズインスタンス (v16)
    //
    // v16 でスヌーズを AlarmKit ネイティブ (.countdown) から自前実装 (.custom) に変更した。
    // 「スヌーズ」を押すと SnoozeAndOpenIntent がアプリを開き、N 分後に鳴る
    // 一時的なアラーム (= スヌーズインスタンス) を新規生成する。
    //
    // スヌーズインスタンスは AlarmItem として保存される。理由:
    //   syncSchedule() は「アプリ側の一覧に無い AlarmKit アラームは停止する」ため、
    //   AlarmItem として持たないと次の同期で消されてしまう。
    // ただしユーザーの一覧を汚さないよう AlarmListView では非表示にし、
    // 発火時刻を過ぎたものは bootstrap で自動削除する。

    /// スヌーズによって自動生成された一時アラームなら true。
    /// true のものは AlarmListView に表示されず、期限切れで自動削除される。
    var isSnoozeInstance: Bool

    /// スヌーズ元となった本来のアラームの ID。
    /// - 抽選履歴をこの ID で共有するため (スヌーズを繰り返しても曲が重複しにくくなる)
    /// - 同じ元アラームに対するスヌーズインスタンスを 1 つに保つため
    /// スヌーズインスタンスをさらにスヌーズした場合も、この値は最初の元アラームを指し続ける。
    var snoozeSourceID: UUID?

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
        randomSourceLibraryFileNames: Set<String> = [],
        isSnoozeInstance: Bool = false,
        snoozeSourceID: UUID? = nil
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
        self.isSnoozeInstance = isSnoozeInstance
        self.snoozeSourceID = snoozeSourceID
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
        case isSnoozeInstance
        case snoozeSourceID
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

        // v16 新フィールド。旧データには存在しないので false / nil にフォールバック。
        self.isSnoozeInstance = try c.decodeIfPresent(Bool.self, forKey: .isSnoozeInstance) ?? false
        self.snoozeSourceID = try c.decodeIfPresent(UUID.self, forKey: .snoozeSourceID)
    }

    // MARK: - Convenience

    /// ID だけを新しくしたコピーを返す (中身はすべて引き継ぐ)。
    ///
    /// なぜ必要か:
    ///   AlarmKit は「一度登録に使った ID」を再利用しても正しく発火しないことがある。
    ///   schedule() 自体はエラーを返さないため気づきにくいが、実際には鳴らない。
    ///   そのためアラームを編集した際は ID を振り直し、AlarmKit から見て
    ///   「まったく新しいアラーム」として登録し直す。
    ///
    ///   (新規作成したアラームは正常に鳴るのに、既存アラームの時刻を変更すると
    ///    鳴らなくなる、という症状の対策)
    func replacingID(with newID: UUID = UUID()) -> AlarmItem {
        AlarmItem(
            id: newID,
            hour: hour,
            minute: minute,
            schedule: schedule,
            enabled: enabled,
            label: label,
            folderRelPath: folderRelPath,
            snoozeEnabled: snoozeEnabled,
            snoozeMinutes: snoozeMinutes,
            soundSourceMode: soundSourceMode,
            customSoundName: customSoundName,
            randomSourceUseFolder: randomSourceUseFolder,
            randomSourceLibraryFileNames: randomSourceLibraryFileNames,
            isSnoozeInstance: isSnoozeInstance,
            snoozeSourceID: snoozeSourceID
        )
    }

    /// このアラームから「N 分後に鳴るスヌーズインスタンス」を作る。
    ///
    /// 音源設定 (モード / 固定音源 / 抽選対象) はすべて引き継ぐので、
    /// スヌーズでも同じソースから曲が選ばれる。ただし ID が変わるため
    /// `.random` モードでは再抽選が走り、**別の曲**になる可能性が高い
    /// (抽選履歴は snoozeSourceID 経由で元アラームと共有される)。
    ///
    /// - Parameters:
    ///   - now: 基準時刻 (テスト用に差し替え可能)
    ///   - calendar: 使用するカレンダー
    /// - Returns: `isSnoozeInstance = true` の一時アラーム。
    func makingSnoozeInstance(now: Date = Date(), calendar: Calendar = .current) -> AlarmItem {
        let fireDate = now.addingTimeInterval(TimeInterval(snoozeMinutes * 60))
        let comps = calendar.dateComponents([.hour, .minute], from: fireDate)

        // 元ラベルを保ちつつスヌーズであることを示す
        let baseLabel = isSnoozeInstance
            ? label   // 既にスヌーズインスタンスなら二重に付けない
            : (label.isEmpty ? "スヌーズ" : "\(label) (スヌーズ)")

        return AlarmItem(
            id: UUID(),
            hour: comps.hour ?? 0,
            minute: comps.minute ?? 0,
            schedule: .oneShotAt(date: fireDate),
            enabled: true,
            label: baseLabel,
            folderRelPath: folderRelPath,
            snoozeEnabled: snoozeEnabled,
            snoozeMinutes: snoozeMinutes,
            soundSourceMode: soundSourceMode,
            customSoundName: customSoundName,
            randomSourceUseFolder: randomSourceUseFolder,
            randomSourceLibraryFileNames: randomSourceLibraryFileNames,
            isSnoozeInstance: true,
            // 既にスヌーズインスタンスなら元を辿り続ける
            snoozeSourceID: snoozeSourceID ?? id
        )
    }

    /// スヌーズインスタンスとして期限切れ (発火時刻を過ぎた) かどうか。
    /// bootstrap 時の自動掃除に使う。通常アラームは常に false。
    func isExpiredSnoozeInstance(now: Date = Date()) -> Bool {
        guard isSnoozeInstance else { return false }
        guard case .oneShotAt(let date) = schedule else { return false }
        return date < now
    }

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
