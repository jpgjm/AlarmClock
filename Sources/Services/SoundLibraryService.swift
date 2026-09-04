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

    /// v46 以前に `UserDefaults` へ履歴を保存していたときのキー接頭辞。
    /// 移行のためだけに残している (例: "SoundHistory.abc123-...")。
    private let historyKeyPrefix = "SoundHistory."

    /// 旧履歴の移行が済んだかどうか。
    private let legacyHistoryMigratedKey = "SoundHistory.migratedToFile"

    // MARK: - Paths

    /// `Library/Sounds/` の URL。無ければ作る。
    /// AlarmKit がカスタム音源を探索するデフォルト経路 (WWDC25 で言及)。
    ///
    /// 【v28】実際の場所は `RuntimeEnvironment` に委ねる。
    ///   LiveContainer 内で動いている場合、自分のコンテナに置いても
    ///   鳴動時にシステムデーモンが見つけられない (デーモンから見た登録者は
    ///   LiveContainer なので、ホストの実コンテナを探しに行く)。
    ///   RuntimeEnvironment が LC_HOME_PATH を見て書き込み先を切り替える。
    private var soundsDirectory: URL {
        let soundsURL = RuntimeEnvironment.alarmKitSoundsDirectory
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

    /// 音源を差し替える際の一時ファイルのプレフィックス (v30)。
    /// 先頭がドットなので隠しファイル扱いになり、走査対象にも入らない。
    private static let temporaryPrefix = ".tmp-"

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

        // 1. 候補を集める
        let candidates = gatherCandidates(
            useFolder: useFolder,
            folderRelPath: folderRelPath,
            libraryFileNames: libraryFileNames,
            allowedExtensions: nil
        )

        guard !candidates.isEmpty else {
            debugPrint("[SoundLibrary] no candidate found (useFolder=\(useFolder), folderRelPath=\(folderRelPath ?? "nil"), libraryFileNames.count=\(libraryFileNames.count))")
            return nil
        }

        // 2〜4. 履歴で絞り込んでランダム選択し、履歴を更新
        guard let draw = pickWithHistory(candidates: candidates, historyID: historyID) else {
            return nil
        }
        let picked = draw.picked
        let excludeCount = draw.excludedCount

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

    // MARK: - 抽選の内部処理 (v30 で prepareAlarmSound から切り出し)

    /// 抽選候補を集める。
    ///
    /// - Parameter allowedExtensions: nil なら `alarmKitSupportedExtensions` 全部。
    ///   値を渡すと、その拡張子のファイルだけに絞る
    ///   (`refreshPreparedSound()` がファイル名を変えずに差し替えるために使う)。
    private func gatherCandidates(
        useFolder: Bool,
        folderRelPath: String?,
        libraryFileNames: Set<String>,
        allowedExtensions: Set<String>?
    ) -> [URL] {
        let allowed = allowedExtensions ?? Self.alarmKitSupportedExtensions
        var candidates: [URL] = []

        // フォルダから (Documents 配下を再帰走査)
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
                    guard allowed.contains(ext) else { continue }
                    if url.lastPathComponent.hasPrefix(Self.preparedPrefix) { continue }
                    candidates.append(url)
                }
            }
        }

        // Library/Sounds の選択済みファイルから
        for name in libraryFileNames {
            let url = soundsDirectory.appendingPathComponent(name)
            guard allowed.contains(url.pathExtension.lowercased()) else { continue }
            if fm.fileExists(atPath: url.path) {
                candidates.append(url)
            }
        }

        return candidates
    }

    /// 履歴で絞り込んでランダムに 1 曲選び、履歴を更新して返す。
    ///
    /// 【v47】実装は `Shared/SoundShuffle.swift` に移した。
    ///   同じ抽選ルールを LiveContainer のプロセスからも使う必要があるため。
    ///   停止ボタンで走る dylib (`AlarmClockGuestPerform`) と**同一のソース**が
    ///   同一の履歴ファイルを読む。ここは薄い委譲だけ。
    private func pickWithHistory(candidates: [URL], historyID: UUID) -> (picked: URL, excludedCount: Int)? {
        guard let draw = SoundShuffle.pick(candidates: candidates,
                                           historyID: historyID.uuidString,
                                           store: historyStore) else { return nil }
        return (draw.picked, draw.excludedCount)
    }

    // MARK: - 登録を維持したまま音源だけ差し替える (v30)

    /// 既に AlarmKit に登録されているアラームについて、**登録を触らずに**
    /// prepared ファイルの中身だけを別の曲で上書きする。
    ///
    /// 狙い:
    ///   従来の再抽選は「新しい ID で登録し直す」方式だった。これには 2 つ問題がある。
    ///     - cancel と schedule が競合して com.apple.AlarmKit.Alarm error 0 になる
    ///       (v22 で差分同期にした原因)
    ///     - ID が変わるので抽選履歴 (キーがアラーム ID) が毎回リセットされ、
    ///       「連日同じ曲を避ける」が一度も機能していなかった
    ///
    ///   ファイル名を固定したまま中身だけ差し替えれば、AlarmKit の登録は一切
    ///   変更不要になり、上の 2 つが同時に解消する。
    ///   LiveContainer 内では停止 Intent が使えないため、アプリを開いたときに
    ///   これを走らせることが唯一の再抽選手段になる。
    ///
    /// 前提と制限:
    ///   - 対象は `prepared-{alarmID}.{ext}` が実在するアラームだけ。
    ///     ユーザーがインポートした音源を直接指定している場合は
    ///     **上書きしてはいけない** (実体を壊す) ので何もしない。
    ///   - 拡張子は変えられない。登録済みのファイル名を維持する必要があるため、
    ///     候補も同じ拡張子のものだけに絞る。
    ///   - 差し替え中に発火すると壊れた音を鳴らしかねないので、
    ///     一時ファイルに書いてから `replaceItemAt` で原子的に入れ替える。
    ///
    /// - Returns: 差し替えた場合はその内容。対象外 / 候補なし / 失敗時は nil。
    func refreshPreparedSound(
        alarmID: UUID,
        historyKeyID: UUID? = nil,
        useFolder: Bool,
        folderRelPath: String?,
        libraryFileNames: Set<String>
    ) async -> PreparedSound? {
        // 0. 差し替え中に落ちた場合の残骸を掃除する。
        //    FLAC は 1 曲数十 MB になることがあるので、放置すると無視できない。
        sweepTemporaryFiles()

        // 1. 現在の prepared ファイルを特定する。無ければ対象外。
        guard let current = currentPreparedFile(alarmID: alarmID) else {
            return nil
        }
        let ext = current.pathExtension.lowercased()

        // 2. 同じ拡張子の候補だけを集める (ファイル名を変えられないため)
        let candidates = gatherCandidates(
            useFolder: useFolder,
            folderRelPath: folderRelPath,
            libraryFileNames: libraryFileNames,
            allowedExtensions: [ext]
        )
        guard candidates.count > 1 else {
            // 候補が 1 つ以下なら差し替える意味がない (同じ曲になる)
            return nil
        }

        // 3. 抽選
        let historyID = historyKeyID ?? alarmID
        guard let draw = pickWithHistory(candidates: candidates, historyID: historyID) else {
            return nil
        }

        // 既に同じ曲が入っているなら書き込まない (無駄な I/O を避ける)
        if draw.picked.standardizedFileURL == current.standardizedFileURL {
            return nil
        }

        // 4. 一時ファイル経由で原子的に差し替える
        let tmpURL = soundsDirectory
            .appendingPathComponent("\(Self.temporaryPrefix)\(UUID().uuidString).\(ext)")
        do {
            try? fm.removeItem(at: tmpURL)
            try fm.copyItem(at: draw.picked, to: tmpURL)
            _ = try fm.replaceItemAt(current, withItemAt: tmpURL)
        } catch {
            debugPrint("[SoundLibrary] refresh failed: \(error)")
            try? fm.removeItem(at: tmpURL)
            return nil
        }

        let sourceName = entry(byFileName: draw.picked.lastPathComponent)?.displayName
            ?? draw.picked.lastPathComponent

        debugPrint("[SoundLibrary] refreshed \(current.lastPathComponent) <- \(draw.picked.lastPathComponent)")

        return PreparedSound(
            alarmKitName: current.lastPathComponent,
            sourceName: sourceName,
            candidateCount: candidates.count,
            excludedCount: draw.excludedCount,
            deliveredExtension: ext
        )
    }

    /// 診断表示用。現在 prepared として置かれているファイルの概要を返す。
    ///
    /// ファイル名は `prepared-{alarmID}.{ext}` で固定なので曲名は分からない。
    /// 代わりに **サイズと更新時刻**を返す。差し替えが起きたかどうかは
    /// この 2 つが変わったかで判定できる (実際に鳴らさなくても確認できる)。
    func currentPreparedSoundDescription(alarmID: UUID) -> String? {
        guard let url = currentPreparedFile(alarmID: alarmID) else { return nil }
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
        let modified = attrs?[.modificationDate] as? Date

        let sizeText = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        guard let modified else { return sizeText }

        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss"
        return "\(sizeText) / 更新 \(f.string(from: modified))"
    }

    /// 差し替えの途中で中断した場合に残る `.tmp-*` を削除する。
    private func sweepTemporaryFiles() {
        guard let contents = try? fm.contentsOfDirectory(atPath: soundsDirectory.path) else {
            return
        }
        for name in contents where name.hasPrefix(Self.temporaryPrefix) {
            try? fm.removeItem(at: soundsDirectory.appendingPathComponent(name))
        }
    }

    /// 指定アラームの prepared ファイル (拡張子不問) を 1 つ返す。無ければ nil。
    /// 何らかの理由で複数ある場合は最初に見つかったものを使う。
    private func currentPreparedFile(alarmID: UUID) -> URL? {
        let prefix = "\(Self.preparedPrefix)\(alarmID.uuidString)."
        guard let contents = try? fm.contentsOfDirectory(atPath: soundsDirectory.path) else {
            return nil
        }
        guard let name = contents.first(where: { $0.hasPrefix(prefix) }) else {
            return nil
        }
        return soundsDirectory.appendingPathComponent(name)
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
    //
    // 【v47】UserDefaults から**ファイル**へ移した。
    //
    //   停止ボタンで走る dylib (`LCGuestIntentPerform`) は
    //   **LiveContainer のプロセス**で動くため、`UserDefaults.standard` は
    //   LiveContainer の設定を指す。AlarmClock のものではない。
    //   そのままでは履歴を共有できなかった。
    //
    //   ファイルなら、パスさえ渡せばどちらの文脈からも同じものを読める。
    //   保管場所とフォーマットを決めているのは**このアプリ側**で、
    //   LiveContainer は関知しない。

    /// 抽選履歴の保管庫。実体は `Documents/.sound-history.json`。
    ///
    /// ここは**アプリ自身の** Documents。LiveContainer 内でも、ゲストから見た
    /// `.documentDirectory` は自分のコンテナを指すので、これで正しい。
    /// dylib 側は同じ場所を LiveContainer のホームからの相対パスで受け取る。
    private var historyStore: ShuffleHistoryStore {
        let documents = fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
        return ShuffleHistoryStore(documents: documents)
    }

    /// アラームごとの抽選履歴 (直近選ばれたファイル名、新しい順)。
    ///
    /// 「AlarmSound/foo.mp3」のような相対パスではなく、単なる `lastPathComponent`
    /// (例 "foo.mp3") を格納する。フォルダを変えた場合や同名ファイルが
    /// 別サブディレクトリにあるようなエッジケースでは効き目が薄れるが、
    /// 実用上はこれで十分。
    func loadHistory(alarmID: UUID) -> [String] {
        migrateLegacyHistoryIfNeeded()
        return historyStore.load(alarmID: alarmID.uuidString)
    }

    /// 指定アラーム ID の抽選履歴だけをクリア (prepared ファイルは残す)。
    func clearHistory(alarmID: UUID) {
        historyStore.clear(alarmID: alarmID.uuidString)
    }

    /// 抽選履歴を別の ID に引き継ぐ。
    ///
    /// アラームを編集した際に ID を振り直す (AlarmItem.replacingID) 運用のため、
    /// そのままだと「連日同じ曲を避ける」履歴が編集のたびに失われてしまう。
    ///
    /// 【v41 の注意】`AlarmService.cancel` は内部で `clearHistory` を呼ぶので、
    /// 呼び出し側はこれを `cancel` より**先**に実行すること。
    func migrateHistory(from oldID: UUID, to newID: UUID) {
        guard oldID != newID else { return }
        migrateLegacyHistoryIfNeeded()
        let before = historyStore.load(alarmID: oldID.uuidString).count
        historyStore.migrate(from: oldID.uuidString, to: newID.uuidString)
        debugPrint("[SoundLibrary] migrated history \(oldID) -> \(newID) (\(before) entries)")
    }

    /// v46 以前の `UserDefaults` に残っている履歴を、一度だけファイルへ移す。
    ///
    /// 移行し終えたら `UserDefaults` 側は消す。二重に持つと、
    /// どちらが正かで混乱するため。
    private func migrateLegacyHistoryIfNeeded() {
        guard !defaults.bool(forKey: legacyHistoryMigratedKey) else { return }

        var legacy: [String: [String]] = [:]
        for (key, value) in defaults.dictionaryRepresentation()
        where key.hasPrefix(historyKeyPrefix) {
            guard let history = value as? [String], !history.isEmpty else { continue }
            let alarmID = String(key.dropFirst(historyKeyPrefix.count))
            legacy[alarmID] = history
        }

        if !legacy.isEmpty {
            historyStore.importIfNeeded(legacy)
            debugPrint("[SoundLibrary] imported \(legacy.count) legacy history entries")
        }
        for key in legacy.keys {
            defaults.removeObject(forKey: historyKeyPrefix + key)
        }
        defaults.set(true, forKey: legacyHistoryMigratedKey)
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
