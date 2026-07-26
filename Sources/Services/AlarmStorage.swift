//
//  AlarmStorage.swift
//  AlarmClock
//
//  アラーム一覧を UserDefaults に Codable JSON で保存する簡易永続化。
//  AlarmKit 側にもアラームは登録されるが、アプリ独自の設定 (音量/フォルダ/フェードイン等)
//  はここでしか持たないため、単一の source of truth はこの storage。
//

import Foundation

final class AlarmStorage {
    static let shared = AlarmStorage()

    private let key = "alarms_v1"
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> [AlarmItem] {
        guard let data = defaults.data(forKey: key) else { return [] }
        let decoder = JSONDecoder()
        return (try? decoder.decode([AlarmItem].self, from: data)) ?? []
    }

    func save(_ alarms: [AlarmItem]) {
        let encoder = JSONEncoder()
        if let data = try? encoder.encode(alarms) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Timezone tracking (PDF: 3 層 TZ 補正 の共有ストレージ)

    private let tzKey = "lastKnownTimeZone"

    var lastKnownTimeZoneIdentifier: String? {
        get { defaults.string(forKey: tzKey) }
        set { defaults.set(newValue, forKey: tzKey) }
    }
}
