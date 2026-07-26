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

import AVFoundation
import Foundation
import MediaPlayer

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

    /// アラームごとの抽選履歴を UserDefaults に保存する時のキー接頭辞。
    /// アラーム ID を後ろに繋げてキーにする (例: "SoundHistory.abc123-...").
    private let historyKeyPrefix = "SoundHistory."

    /// 直近何曲までを "履歴として除外候補にする" か。
    /// 大きくすると連日同じ曲を避けられる一方、フォルダ内の候補数が小さいと
    /// 効果が無くなる。10 なら 10 日連続でユニークに近い曲が回る (候補が十分ある場合)。
    private let maxHistorySize = 10

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

    // MARK: - Music Library からの取り込み

    /// Apple Music の曲を取り込めなかった時のエラー。
    enum MusicImportError: Error, LocalizedError {
        case noAssetURL          // assetURL が nil (DRM 保護 / 未ダウンロード)
        case exportFailed(String) // AVAssetExportSession が失敗した
        case fileSystemError(Error)

        var errorDescription: String? {
            switch self {
            case .noAssetURL:
                return "この曲は Apple Music のサブスクリプション曲、またはデバイスに未ダウンロードのため、アラーム音として使用できません。iTunes 同期で取り込んだ曲や、DRM 保護のない曲を選んでください。"
            case .exportFailed(let msg):
                return "曲の書き出しに失敗しました: \(msg)"
            case .fileSystemError(let e):
                return "ファイルの保存に失敗しました: \(e.localizedDescription)"
            }
        }
    }

    /// `MPMediaItem` (音楽ライブラリの曲) を Library/Sounds/{UUID}.m4a にエクスポートして
    /// カスタム音源として登録する。
    ///
    /// 動作:
    ///   1. `mediaItem.assetURL` を取得 (nil なら DRM で失敗)
    ///   2. `AVAssetExportSession` で `AVAssetExportPresetAppleM4A` として m4a エクスポート
    ///   3. エクスポート完了後に SoundEntry を作成してメタデータに追加
    ///
    /// 表示名: "曲名 - アーティスト名" (どちらか欠けていたら省略)
    ///
    /// 注意: Apple Music のサブスクリプション曲は基本的に失敗する
    /// (assetURL が nil、または DRM 保護で書き出せない)。UI にエラーを出して選び直しを促す。
    func importFromMediaItem(_ mediaItem: MPMediaItem) async throws -> SoundEntry {
        // 1. assetURL の取得
        guard let assetURL = mediaItem.assetURL else {
            throw MusicImportError.noAssetURL
        }

        // 2. 出力先を決定
        let uuid = UUID()
        let ext = "m4a"
        let destName = "\(uuid.uuidString).\(ext)"
        let destURL = soundsDirectory.appendingPathComponent(destName)

        // 既存ファイルがあれば消す (通常ここには来ない)
        if fm.fileExists(atPath: destURL.path) {
            try? fm.removeItem(at: destURL)
        }

        // 3. AVAssetExportSession でエクスポート
        let asset = AVURLAsset(url: assetURL)
        guard let exporter = AVAssetExportSession(
            asset: asset,
            presetName: AVAssetExportPresetAppleM4A
        ) else {
            throw MusicImportError.exportFailed("AVAssetExportSession を生成できませんでした")
        }
        exporter.outputURL = destURL
        exporter.outputFileType = .m4a

        // export() は iOS 18 以降で async のオーバーロードあり
        await exporter.export()

        switch exporter.status {
        case .completed:
            break
        case .failed:
            let msg = exporter.error?.localizedDescription ?? "不明なエラー"
            throw MusicImportError.exportFailed(msg)
        case .cancelled:
            throw MusicImportError.exportFailed("キャンセルされました")
        default:
            throw MusicImportError.exportFailed("状態: \(exporter.status.rawValue)")
        }

        // 4. 表示名を組み立てる
        let title = (mediaItem.title ?? "").trimmingCharacters(in: .whitespaces)
        let artist = (mediaItem.artist ?? "").trimmingCharacters(in: .whitespaces)
        let displayName: String
        if !title.isEmpty && !artist.isEmpty {
            displayName = "\(title) - \(artist)"
        } else if !title.isEmpty {
            displayName = title
        } else if !artist.isEmpty {
            displayName = artist
        } else {
            displayName = uuid.uuidString
        }

        // 5. メタデータに追加
        let entry = SoundEntry(id: uuid, fileName: destName, displayName: displayName)
        var all = entries()
        all.append(entry)
        saveEntries(all)
        return entry
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
    /// v11 追加: **抽選履歴** で直近選ばれた曲を除外する。
    ///   - 候補が多い時ほど広く除外 (候補の半分 or 履歴上限のうち小さい方)
    ///   - 候補が 1 曲しかない時は履歴を無視 (そうしないと再生できなくなる)
    ///   - 候補が 2 曲以上ある時は少なくとも 1 曲は残る
    ///   - 選ばれた曲は履歴の先頭に記録される
    ///
    /// - Parameters:
    ///   - alarmID: AlarmItem.id (ファイル名衝突回避のキー + 履歴のキー)
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

        guard !candidates.isEmpty else {
            debugPrint("[SoundLibrary] no candidate found in \(targetDir.path)")
            return nil
        }

        // 3. 履歴を使った絞り込み (v11)
        //   除外数の決定ルール:
        //     - 履歴数と、候補の半数 (切り捨て) のうち小さい方
        //     - ただし候補が 2 曲以上ある場合、必ず 1 曲は残るよう excludeCount <= candidates.count - 1 に制限
        //     - 候補が 1 曲しかない場合は履歴を無視 (excludeCount = 0)
        let history = loadHistory(alarmID: alarmID)
        let excludeCount: Int
        if candidates.count <= 1 {
            excludeCount = 0
        } else {
            let ideal = min(history.count, candidates.count / 2)
            excludeCount = min(ideal, candidates.count - 1)
        }
        let excludeSet = Set(history.prefix(excludeCount))

        // 除外を適用した候補
        var filtered = candidates.filter { !excludeSet.contains($0.lastPathComponent) }
        if filtered.isEmpty {
            // 除外が強すぎて空になった場合は履歴を無視して全候補から選ぶ (安全網)
            filtered = candidates
        }

        // 4. ランダム選択
        guard let picked = filtered.randomElement() else {
            return nil
        }

        // 5. 履歴を更新 (先頭に追加、既に同じファイル名があれば除去して重複防止、上限で切り詰め)
        var newHistory = [picked.lastPathComponent]
            + history.filter { $0 != picked.lastPathComponent }
        if newHistory.count > maxHistorySize {
            newHistory = Array(newHistory.prefix(maxHistorySize))
        }
        saveHistory(alarmID: alarmID, history: newHistory)

        // 6. Library/Sounds/prepared-{alarmID}.{ext} にコピー (既存は削除)
        let ext = picked.pathExtension.lowercased()
        let destName = "\(Self.preparedPrefix)\(alarmID.uuidString).\(ext)"
        let destURL = soundsDirectory.appendingPathComponent(destName)

        // 同じアラーム ID の既存 prepared ファイル (拡張子違いも含む) を全部消す
        removePreparedFiles(alarmID: alarmID)

        do {
            try fm.copyItem(at: picked, to: destURL)
        } catch {
            debugPrint("[SoundLibrary] prepared copy failed: \(error)")
            return nil
        }

        debugPrint("[SoundLibrary] prepared \(destName) <- \(picked.lastPathComponent) (excluded \(excludeCount) from history)")
        return destName
    }

    /// 指定アラーム ID に対応する prepared 音源 (拡張子不問) と抽選履歴を削除する。
    /// アラーム削除時 (AlarmService.cancel) から呼ばれる。
    /// 履歴もクリアするので、再作成後に同じ ID を使い回しても "以前の続き" にはならない。
    func cleanupPreparedSound(alarmID: UUID) {
        removePreparedFiles(alarmID: alarmID)
        clearHistory(alarmID: alarmID)
    }

    /// prepared ファイルの実体のみを削除 (履歴はそのまま)。
    /// prepareAlarmSound() の内部で「再抽選前の掃除」として使う。
    private func removePreparedFiles(alarmID: UUID) {
        let prefix = "\(Self.preparedPrefix)\(alarmID.uuidString)."
        if let contents = try? fm.contentsOfDirectory(atPath: soundsDirectory.path) {
            for name in contents where name.hasPrefix(prefix) {
                try? fm.removeItem(at: soundsDirectory.appendingPathComponent(name))
            }
        }
    }

    // MARK: - History (抽選履歴の永続化)

    /// アラームごとの抽選履歴 (直近選ばれたファイル名、新しい順)。
    /// 「AlarmSound/foo.mp3」のような相対パスではなく、単なる `lastPathComponent`
    /// (例 "foo.mp3") を格納する。フォルダを変えた場合や同名ファイルが別サブディレクトリに
    /// あるようなエッジケースでは効き目が薄れるが、実用上はこれで十分。
    func loadHistory(alarmID: UUID) -> [String] {
        defaults.stringArray(forKey: historyKey(alarmID: alarmID)) ?? []
    }

    private func saveHistory(alarmID: UUID, history: [String]) {
        defaults.set(history, forKey: historyKey(alarmID: alarmID))
    }

    /// 指定アラーム ID の抽選履歴だけをクリア (prepared ファイルは残す)。
    /// UI 側から「履歴リセット」を押した時に呼び出す想定 (今回未提供)。
    func clearHistory(alarmID: UUID) {
        defaults.removeObject(forKey: historyKey(alarmID: alarmID))
    }

    private func historyKey(alarmID: UUID) -> String {
        "\(historyKeyPrefix)\(alarmID.uuidString)"
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
