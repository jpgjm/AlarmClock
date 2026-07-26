//
//  SoundLibraryService.swift
//  AlarmClock
//
//  AlarmKit の `AlertConfiguration.AlertSound.named("filename.ext")` に渡す
//  カスタム音源ファイルを管理する。
//
//  ファイル配置:
//    App コンテナ内の `Library/Sounds/{UUID}.{ext}` に保存する。
//    AlarmKit は `Library/Sounds/` フォルダ配下のファイルをデフォルトで探索するため、
//    ここに置いたファイルは `.named("filename.ext")` だけで参照できる。
//    (WWDC25 Session 230 で明言されている経路)
//
//  対応形式:
//    .wav / .aiff / .caf を主にサポート (DayAfterTomorrow と同じ)。
//    .mp3 / .m4a も AlarmKit の仕様上使えるはずだが iOS 26.0 に既知バグあり。
//    iOS 26.1+ ならおおむね動く。
//
//  メタデータ:
//    ファイル名は衝突回避のため UUID にする。
//    ユーザー表示名は SoundEntry.displayName に保持し、UserDefaults に別途保存する。
//

import Foundation

/// カスタム音源 1 件のメタデータ。
/// - fileName: `Library/Sounds/` 配下のファイル名 (拡張子込み、例 "abc123.wav")。
///   AlarmKit の `.named(fileName)` にそのまま渡す文字列。
/// - displayName: ユーザーが選んだ元ファイルのオリジナル名 (拡張子除去)。UI 表示用。
struct SoundEntry: Codable, Identifiable, Equatable {
    var id: UUID
    var fileName: String
    var displayName: String

    /// AlarmKit の `.named(_:)` に渡す文字列。fileName と同じ。
    var alarmKitName: String { fileName }
}

@MainActor
final class SoundLibraryService {
    static let shared = SoundLibraryService()

    private let fm = FileManager.default
    private let defaults = UserDefaults.standard
    private let metadataKey = "SoundLibrary.entries"

    // MARK: - Paths

    /// `Library/Sounds/` の URL。無ければ作る。
    /// AlarmKit がカスタム音源を探索するデフォルト経路 (WWDC25 で言及)。
    private var soundsDirectory: URL {
        let libraryURL = fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let soundsURL = libraryURL.appendingPathComponent("Sounds", isDirectory: true)
        if !fm.fileExists(atPath: soundsURL.path) {
            try? fm.createDirectory(at: soundsURL, withIntermediateDirectories: true)
        }
        return soundsURL
    }

    /// AlarmKit の sound: 指定に使える拡張子。
    /// - wav / aiff / caf: 確実に動く (WWDC25 で言及されている形式)
    /// - mp3 / m4a / aac: iOS 26.0 でバグあり (26.1+ 改善)、動く見込みだが慎重
    /// - flac: AlarmKit 非対応と思われる (システム標準の CoreAudio が対応しないため)
    static let alarmKitSupportedExtensions: Set<String> = [
        "wav", "aiff", "aif", "caf", "mp3", "m4a", "aac"
    ]

    // MARK: - CRUD

    /// 現在ライブラリに登録されているカスタム音源 (UI 表示順に返す)。
    /// prepareAlarmSound() が置く "prepared-" プレフィックスのファイルは表示から除外する。
    func entries() -> [SoundEntry] {
        guard let data = defaults.data(forKey: metadataKey),
              let list = try? JSONDecoder().decode([SoundEntry].self, from: data) else {
            return []
        }
        // 実体ファイルが消えていたらメタも消す (整合性維持)。
        let alive = list.filter { entry in
            fm.fileExists(atPath: soundsDirectory.appendingPathComponent(entry.fileName).path)
        }
        if alive.count != list.count {
            saveEntries(alive)
        }
        return alive
    }

    /// 指定 fileName に対応するエントリを取得。
    func entry(byFileName name: String) -> SoundEntry? {
        entries().first { $0.fileName == name }
    }

    // MARK: - Prepared alarm sound (フォルダから抽選)

    /// アラームごとの "動的抽選音源" のファイル名プレフィックス。
    /// entries() には出さない (ユーザーがインポートしたものと区別)。
    private static let preparedPrefix = "prepared-"

    /// アラーム 1 件用に、Documents 配下のフォルダから 1 曲ランダム抽選して
    /// Library/Sounds/prepared-{alarmID}.{ext} にコピーする。
    ///
    /// 呼ばれるタイミング: AlarmService.schedule() の直前 (毎回スケジュール登録の
    /// たびに抽選し直す)。アプリを起動するたびに翌回のアラーム音がランダムに変わる。
    ///
    /// - Parameters:
    ///   - alarmID: AlarmItem.id (ファイル名衝突回避のキー)
    ///   - folderRelPath: Documents ルートからの相対パス。nil または空文字なら Documents 直下全体。
    /// - Returns: AlarmKit の `.named(_:)` に渡すファイル名 (例 "prepared-abc123.wav")。
    ///   対象曲が無い / コピー失敗時は nil。
    func prepareAlarmSound(alarmID: UUID, folderRelPath: String?) -> String? {
        // 1. Documents 内の候補フォルダを決定
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let targetDir: URL
        if let rel = folderRelPath, !rel.isEmpty {
            targetDir = docs.appendingPathComponent(rel)
        } else {
            targetDir = docs
        }

        // 2. 対象フォルダ配下 (再帰) から AlarmKit 対応拡張子の曲を列挙
        guard let enumerator = fm.enumerator(
            at: targetDir,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var candidates: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            guard Self.alarmKitSupportedExtensions.contains(ext) else { continue }
            // Library/Sounds に置いた prepared-* を Documents 内には置かないはずだが念のため
            if url.lastPathComponent.hasPrefix(Self.preparedPrefix) { continue }
            candidates.append(url)
        }

        guard let picked = candidates.randomElement() else {
            debugPrint("[SoundLibrary] no candidate found in \(targetDir.path)")
            return nil
        }

        // 3. Library/Sounds/prepared-{alarmID}.{ext} にコピー (既存は削除)
        let ext = picked.pathExtension.lowercased()
        let destName = "\(Self.preparedPrefix)\(alarmID.uuidString).\(ext)"
        let destURL = soundsDirectory.appendingPathComponent(destName)

        // 同じアラーム ID の既存 prepared ファイル (拡張子違いも含む) を全部消す
        cleanupPreparedSound(alarmID: alarmID)

        do {
            try fm.copyItem(at: picked, to: destURL)
        } catch {
            debugPrint("[SoundLibrary] prepared copy failed: \(error)")
            return nil
        }

        debugPrint("[SoundLibrary] prepared \(destName) <- \(picked.lastPathComponent)")
        return destName
    }

    /// 指定アラーム ID に対応する prepared 音源 (拡張子不問) を削除する。
    /// アラーム削除時、または prepareAlarmSound で作り直す前に呼ぶ。
    func cleanupPreparedSound(alarmID: UUID) {
        let prefix = "\(Self.preparedPrefix)\(alarmID.uuidString)."
        if let contents = try? fm.contentsOfDirectory(atPath: soundsDirectory.path) {
            for name in contents where name.hasPrefix(prefix) {
                try? fm.removeItem(at: soundsDirectory.appendingPathComponent(name))
            }
        }
    }

    /// 元ファイル URL (Files アプリ / ドキュメントピッカーで選ばれた security-scoped URL) から取り込む。
    ///
    /// - Parameter sourceURL: security-scoped URL (`file://.../foo.wav`)。呼び出し側で
    ///   `startAccessingSecurityScopedResource()` を必ず呼んでおくこと。
    /// - Returns: 追加された SoundEntry。失敗時 nil。
    @discardableResult
    func importSound(from sourceURL: URL) -> SoundEntry? {
        let ext = sourceURL.pathExtension.lowercased()
        // 拡張子ホワイトリスト (AlarmKit が読める見込みの高い形式のみ)。
        // NOTE: mp3/m4a は iOS 26.0 のバグでエラー音になる報告あり。
        // 26.1+ ならおおむね通る。
        let allowed: Set<String> = ["wav", "aiff", "aif", "caf", "mp3", "m4a"]
        guard allowed.contains(ext) else {
            debugPrint("[SoundLibrary] unsupported extension: \(ext)")
            return nil
        }

        let uuid = UUID()
        let destName = "\(uuid.uuidString).\(ext)"
        let destURL = soundsDirectory.appendingPathComponent(destName)

        // オリジナル名 (拡張子除去) を表示名として保持。
        let originalName = sourceURL.deletingPathExtension().lastPathComponent
        let displayName = originalName.isEmpty ? uuid.uuidString : originalName

        do {
            // 既に同名ファイルがあれば上書き (通常ここには来ない)。
            if fm.fileExists(atPath: destURL.path) {
                try fm.removeItem(at: destURL)
            }
            try fm.copyItem(at: sourceURL, to: destURL)
        } catch {
            debugPrint("[SoundLibrary] import copy failed: \(error)")
            return nil
        }

        let entry = SoundEntry(id: uuid, fileName: destName, displayName: displayName)
        var all = entries()
        all.append(entry)
        saveEntries(all)
        return entry
    }

    /// カスタム音源を削除 (実体ファイル + メタデータ)。
    func delete(_ entry: SoundEntry) {
        let url = soundsDirectory.appendingPathComponent(entry.fileName)
        try? fm.removeItem(at: url)
        let all = entries().filter { $0.id != entry.id }
        saveEntries(all)
    }

    // MARK: - Persistence

    private func saveEntries(_ entries: [SoundEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: metadataKey)
        }
    }
}
