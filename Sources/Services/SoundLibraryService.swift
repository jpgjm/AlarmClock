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

/// ランダム抽選の結果。
///
/// ログに「実際にどの曲が選ばれたか」を残せるよう、AlarmKit に渡す名前だけでなく
/// 抽選元の曲名や候補数も返す。これにより、連日同じ曲が選ばれていないか、
/// 候補が十分にあるかを診断画面から確認できる。
struct PreparedSound {
    /// AlarmKit の `.named(_:)` に渡すファイル名。
    let alarmKitName: String
    /// 抽選元の曲名 (インポート済み音源なら「曲名 - アーティスト名」)。
    let sourceName: String
    /// 抽選対象になった候補の総数。
    let candidateCount: Int
    /// 履歴によって除外された曲数。
    let excludedCount: Int
    /// 実際に AlarmKit へ渡したファイルの拡張子。
    /// FLAC 直接再生を試している間、何が渡されたかログで確認するために使う。
    let deliveredExtension: String
}

/// カスタム音源の管理。
///
/// 【v26】`@MainActor` を外した。
///   App Intent から音源の抽選を行うため、アプリ非起動時にも使えるようにする。
///   保持している状態は FileManager / UserDefaults / 定数のみ (すべて let) で、
///   いずれもスレッドセーフなので `@unchecked Sendable` として共有できる。
final class SoundLibraryService: @unchecked Sendable {
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

    /// AlarmKit の sound: に渡せる拡張子。
    ///
    /// FLAC について:
    ///   iOS 11 以降 Core Audio / AVFoundation が FLAC の読み込みに対応しており、
    ///   AlarmKit も **そのまま受け付ける** ことを実機で確認済み (2026-07-27 のログ)。
    ///   一時期 m4a への変換を挟んでいたが、変換に 3〜4 秒かかり
    ///   App Intent のタイムアウトを招く危険があったため撤去した。
    ///
    /// 各形式の状況:
    ///   - wav / aiff / caf : 実機で動作確認済み。WWDC25 でも推奨されている
    ///   - flac             : 実機で動作確認済み (変換不要)
    ///   - mp3 / m4a / aac  : 動く見込み。iOS 26.0 にバグ報告あり (26.1+ で改善)
    static let alarmKitSupportedExtensions: Set<String> = [
        "wav", "aiff", "aif", "caf", "mp3", "m4a", "aac", "flac"
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

    /// アラーム 1 件用に、指定された複数のソースから 1 曲ランダム抽選する。
    ///
    /// ソース:
    ///   - useFolder + folderRelPath: Documents 配下のフォルダから (再帰列挙)
    ///   - libraryFileNames: Library/Sounds/ に既にあるファイル (SoundEntry として登録済み)
    ///
    /// 抽選結果の扱い:
    ///   - Documents 内のファイル → Library/Sounds/prepared-{alarmID}.{ext} にコピーして
    ///     そのファイル名を返す (AlarmKit の探索経路に置くため)
    ///   - Library/Sounds 内のファイル → コピー不要、そのファイル名をそのまま返す
    ///     (無駄なコピーを避けて容量節約)
    ///
    /// 履歴: v11 の除外ロジック (連日同じ曲を避ける) はそのまま適用。
    /// ファイル名 (lastPathComponent) をキーに履歴を保存する。
    ///
    /// - Parameters:
    ///   - alarmID: AlarmItem.id (prepared ファイル名のキー)
    ///   - historyKeyID: 抽選履歴を引くキー。nil なら alarmID を使う。
    ///     スヌーズインスタンスでは元アラームの ID を渡すことで履歴を共有し、
    ///     「元アラーム → スヌーズ 1 → スヌーズ 2」で同じ曲が連続しにくくなる。
    ///   - useFolder: フォルダを抽選対象に含めるか
    ///   - folderRelPath: Documents からの相対パス。nil or 空文字なら Documents 直下全体。useFolder=false なら無視される。
    ///   - libraryFileNames: Library/Sounds に置かれた既存ファイル名の集合。空集合なら Library/Sounds 側からは何も候補が出ない。
    /// - Returns: AlarmKit の `.named(_:)` に渡すファイル名。抽選対象なし / コピー失敗時は nil。
    func prepareAlarmSound(
        alarmID: UUID,
        historyKeyID: UUID? = nil,
        useFolder: Bool,
        folderRelPath: String?,
        libraryFileNames: Set<String>
    ) async -> PreparedSound? {
        // 抽選履歴のキー (スヌーズインスタンスは元アラームと共有する)
        let historyID = historyKeyID ?? alarmID

        var candidates: [URL] = []

        // 1a. フォルダから候補を集める
        if useFolder, let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let targetDir: URL
            if let rel = folderRelPath, !rel.isEmpty {
                targetDir = docs.appendingPathComponent(rel)
            } else {
                targetDir = docs
            }
            if let enumerator = fm.enumerator(
                at: targetDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    let ext = url.pathExtension.lowercased()
                    guard Self.alarmKitSupportedExtensions.contains(ext) else { continue }
                    if url.lastPathComponent.hasPrefix(Self.preparedPrefix) { continue }
                    candidates.append(url)
                }
            }
        }

        // 1b. Library/Sounds から選択済みファイルを候補に追加
        for name in libraryFileNames {
            let url = soundsDirectory.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) {
                candidates.append(url)
            }
        }

        guard !candidates.isEmpty else {
            debugPrint("[SoundLibrary] no candidate found (useFolder=\(useFolder), folderRelPath=\(folderRelPath ?? "nil"), libraryFileNames.count=\(libraryFileNames.count))")
            return nil
        }

        // 2. 履歴を使った絞り込み (連日同じ曲を避ける)
        let history = loadHistory(alarmID: historyID)
        let excludeCount: Int
        if candidates.count <= 1 {
            excludeCount = 0
        } else {
            let ideal = min(history.count, candidates.count / 2)
            excludeCount = min(ideal, candidates.count - 1)
        }
        let excludeSet = Set(history.prefix(excludeCount))

        var filtered = candidates.filter { !excludeSet.contains($0.lastPathComponent) }
        if filtered.isEmpty {
            // 除外が強すぎて空になった場合は履歴を無視 (安全網)
            filtered = candidates
        }

        // 3. ランダム選択
        guard let picked = filtered.randomElement() else {
            return nil
        }

        // 4. 履歴を更新
        var newHistory = [picked.lastPathComponent]
            + history.filter { $0 != picked.lastPathComponent }
        if newHistory.count > maxHistorySize {
            newHistory = Array(newHistory.prefix(maxHistorySize))
        }
        saveHistory(alarmID: historyID, history: newHistory)

        // 5. ファイル配置
        // - Library/Sounds 内なら既に AlarmKit が探索する場所にあるので、コピー不要
        // - Documents 内なら Library/Sounds/prepared-{alarmID}.{ext} にコピー
        let pickedDir = picked.deletingLastPathComponent().standardizedFileURL
        let soundsDir = soundsDirectory.standardizedFileURL

        // 抽選元の曲名。Library/Sounds 内のインポート済み音源なら
        // ユーザーが付けた表示名 (曲名 - アーティスト名) を優先して使う。
        let sourceName = entry(byFileName: picked.lastPathComponent)?.displayName
            ?? picked.lastPathComponent

        if pickedDir.path == soundsDir.path {
            // Library/Sounds 内 → 直接 ファイル名を返す。
            // 過去に作った prepared-* があれば掃除しておく (容量節約)。
            removePreparedFiles(alarmID: alarmID)
            debugPrint("[SoundLibrary] prepared (direct) \(picked.lastPathComponent)")
            return PreparedSound(
                alarmKitName: picked.lastPathComponent,
                sourceName: sourceName,
                candidateCount: candidates.count,
                excludedCount: excludeCount,
                deliveredExtension: picked.pathExtension.lowercased()
            )
        } else {
            // Documents 内 → Library/Sounds/prepared-{alarmID}.{ext} に単純コピー。
            // FLAC も含めて変換は不要 (AlarmKit がそのまま再生できることを確認済み)。
            let ext = picked.pathExtension.lowercased()
            let destName = "\(Self.preparedPrefix)\(alarmID.uuidString).\(ext)"
            let destURL = soundsDirectory.appendingPathComponent(destName)

            removePreparedFiles(alarmID: alarmID)

            do {
                try fm.copyItem(at: picked, to: destURL)
                debugPrint("[SoundLibrary] prepared (copied) \(destName) <- \(picked.lastPathComponent)")
            } catch {
                debugPrint("[SoundLibrary] prepared copy failed: \(error)")
                return nil
            }

            return PreparedSound(
                alarmKitName: destName,
                sourceName: sourceName,
                candidateCount: candidates.count,
                excludedCount: excludeCount,
                deliveredExtension: ext
            )
        }
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

    /// 抽選履歴を別の ID に引き継ぐ。
    ///
    /// アラームを編集した際に ID を振り直す (AlarmItem.replacingID) 運用のため、
    /// そのままだと「連日同じ曲を避ける」履歴が編集のたびに失われてしまう。
    /// 移行元の履歴を移行先にコピーし、移行元は削除する。
    func migrateHistory(from oldID: UUID, to newID: UUID) {
        guard oldID != newID else { return }
        let history = loadHistory(alarmID: oldID)
        guard !history.isEmpty else {
            clearHistory(alarmID: oldID)
            return
        }
        saveHistory(alarmID: newID, history: history)
        clearHistory(alarmID: oldID)
        debugPrint("[SoundLibrary] migrated history \(oldID) -> \(newID) (\(history.count) entries)")
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

        guard Self.alarmKitSupportedExtensions.contains(ext) else {
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

    // MARK: - 診断用

    /// Library/Sounds に指定名のファイルが実在するか。
    /// DiagnosticsView で「音源が見つからないせいで鳴らない」ケースを切り分けるために使う。
    func soundFileExists(named name: String) -> Bool {
        guard !name.isEmpty else { return false }
        return fm.fileExists(atPath: soundsDirectory.appendingPathComponent(name).path)
    }

    /// ランダム抽選の候補になる曲数を数える (実際の抽選は行わない)。
    /// 0 件ならデフォルト音にフォールバックするため、その旨を UI で伝えられる。
    func candidateCount(useFolder: Bool, folderRelPath: String?, libraryFileNames: Set<String>) -> Int {
        var count = 0

        if useFolder, let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
            let targetDir: URL
            if let rel = folderRelPath, !rel.isEmpty {
                targetDir = docs.appendingPathComponent(rel)
            } else {
                targetDir = docs
            }
            if let enumerator = fm.enumerator(
                at: targetDir,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            ) {
                for case let url as URL in enumerator {
                    let ext = url.pathExtension.lowercased()
                    guard Self.alarmKitSupportedExtensions.contains(ext) else { continue }
                    if url.lastPathComponent.hasPrefix(Self.preparedPrefix) { continue }
                    count += 1
                }
            }
        }

        for name in libraryFileNames where soundFileExists(named: name) {
            count += 1
        }

        return count
    }

    // MARK: - Persistence

    private func saveEntries(_ entries: [SoundEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: metadataKey)
        }
    }
}
