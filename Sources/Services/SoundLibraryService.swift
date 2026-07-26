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

    // MARK: - CRUD

    /// 現在ライブラリに登録されているカスタム音源 (UI 表示順に返す)。
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
