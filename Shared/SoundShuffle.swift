//
//  SoundShuffle.swift
//  AlarmHandler
//
//  抽選と履歴の**唯一の実装**。アプリ本体と dylib の両方がここを使う。
//
//  ── なぜ共有ソースなのか ────────────────────────────────────────
//
//  【v48】dylib をアプリに埋め込むのをやめたため、リンクでは共有できない。
//  同じソースを 2 つのターゲットでコンパイルする。ファイルは 1 つのままなので、
//  抽選ルールが二重化することはない。
//
//  このコードは 2 つの文脈で動く。
//
//    1. AlarmClock のプロセス
//       `SoundLibraryService` から呼ばれる。アプリを開いたときの再抽選。
//
//    2. **LiveContainer のプロセス**
//       停止ボタンで `AlarmClockGuestPerform` が呼ばれたとき。
//       dylib は Tweaks 機構で LiveContainer に読み込まれている。
//
//  2 の文脈では `UserDefaults.standard` が **LiveContainer の設定**を指す。
//  `NSHomeDirectory()` も `Bundle.main` も LiveContainer のもの。
//  そのため履歴を `UserDefaults` に置いたままでは 2 つの文脈で共有できない。
//
//  そこで履歴を**ゲストの Documents に置く JSON ファイル**へ移した。
//  ファイルなら、パスさえ渡せばどちらの文脈からでも同じものを読める。
//
//  ── LiveContainer は何も知らない ────────────────────────────────
//
//  ファイル名も JSON の形も除外件数の決め方も、すべてこちらの都合。
//  LiveContainer が知るのは「dylib を dlopen して entry を呼ぶ」だけ。
//
//  以前検討した `replace-file` 方式は、抽選のルールを payload の形で
//  LiveContainer に持ち込んでいた。この方式ではそれが無くなる。
//

import Foundation

/// 抽選履歴の保管庫。
///
/// 実体は 1 つの JSON ファイル。
///
/// ```json
/// { "<alarmID>": ["14. 冬に咲く花.flac", "11. こたつとみかんと.flac", …] }
/// ```
///
/// 配列は**新しい順**。`lastPathComponent` だけを持つ。相対パスにしないのは、
/// フォルダを変えたときに履歴が丸ごと無効になるのを避けるため。
/// 同名ファイルが別のサブフォルダにある場合は効き目が薄れるが、実用上は十分。
struct ShuffleHistoryStore: Sendable {

    /// 保管先のファイル名。
    ///
    /// 【v49】先頭のドットをやめた。隠しファイルだとファイルアプリで
    /// 既定では見えず、中身を確認できないため。
    static let fileName = "sound-history.json"

    /// v48 で使っていた隠しファイル名。移行のためだけに残している。
    static let legacyFileName = ".sound-history.json"

    /// ゲストの Documents。
    ///
    /// アプリのプロセスからは `FileManager` で引ける。
    /// LiveContainer のプロセスからは payload で渡されたパスを使う。
    let documents: URL

    init(documents: URL) {
        self.documents = documents
    }

    private var fileURL: URL {
        documents.appendingPathComponent(Self.fileName)
    }

    private var legacyFileURL: URL {
        documents.appendingPathComponent(Self.legacyFileName)
    }

    /// v48 の隠しファイルが残っていれば、一度だけ新しい名前へ移す。
    ///
    /// 読み込みのたびに呼ばれるが、旧ファイルが無ければ即座に返るので安い。
    private func migrateLegacyFileIfNeeded() {
        let fm = FileManager.default
        guard fm.fileExists(atPath: legacyFileURL.path) else { return }
        guard !fm.fileExists(atPath: fileURL.path) else {
            // 新しい方が既にある。旧ファイルは紛らわしいので消す。
            try? fm.removeItem(at: legacyFileURL)
            return
        }
        try? fm.moveItem(at: legacyFileURL, to: fileURL)
    }

    // MARK: - 読み書き

    func load(alarmID: String) -> [String] {
        loadAll()[alarmID] ?? []
    }

    func save(alarmID: String, history: [String]) {
        var all = loadAll()
        if history.isEmpty {
            all.removeValue(forKey: alarmID)
        } else {
            all[alarmID] = history
        }
        saveAll(all)
    }

    func clear(alarmID: String) {
        var all = loadAll()
        guard all.removeValue(forKey: alarmID) != nil else { return }
        saveAll(all)
    }

    /// 履歴を別の ID に引き継ぐ。
    ///
    /// アラームを編集すると ID を振り直す運用 (`AlarmItem.replacingID`) なので、
    /// これが無いと「連日同じ曲を避ける」履歴が編集のたびに失われる。
    func migrate(from oldID: String, to newID: String) {
        guard oldID != newID else { return }
        var all = loadAll()
        guard let history = all.removeValue(forKey: oldID), !history.isEmpty else {
            saveAll(all)
            return
        }
        all[newID] = history
        saveAll(all)
    }

    /// 一度だけの移行用。`UserDefaults` に残っている履歴を取り込む。
    ///
    /// 既にファイル側にある ID は上書きしない。
    func importIfNeeded(_ legacy: [String: [String]]) {
        guard !legacy.isEmpty else { return }
        var all = loadAll()
        var changed = false
        for (key, value) in legacy where all[key] == nil && !value.isEmpty {
            all[key] = value
            changed = true
        }
        guard changed else { return }
        saveAll(all)
    }

    func loadAll() -> [String: [String]] {
        migrateLegacyFileIfNeeded()
        guard let data = try? Data(contentsOf: fileURL),
              let dict = try? JSONSerialization.jsonObject(with: data)
                as? [String: [String]] else {
            return [:]
        }
        return dict
    }

    private func saveAll(_ all: [String: [String]]) {
        try? FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
                withJSONObject: all, options: [.sortedKeys]) else { return }
        // 途中で落ちても壊れたファイルを残さない。
        try? data.write(to: fileURL, options: .atomic)
    }
}

/// 履歴を見ながら 1 曲選ぶ。
///
/// アプリ側の `SoundLibraryService.pickWithHistory` と、
/// dylib 側の `AlarmClockGuestPerform` の両方がこれを呼ぶ。
/// **抽選ルールの実装はここ 1 か所だけ。**
enum SoundShuffle {

    /// 直近何曲までを履歴として保持するか。
    ///
    /// 大きくすると連日同じ曲を避けられるが、候補が少ないと効果が無くなる。
    /// 10 なら候補が十分あるとき 10 日連続でほぼユニークに回る。
    static let maxHistorySize = 10

    struct Draw: Sendable {
        let picked: URL
        let excludedCount: Int
        let candidateCount: Int
    }

    /// - Parameters:
    ///   - candidates: 抽選対象。空なら nil を返す。
    ///   - historyID: 履歴を引くキー。通常はアラーム ID の文字列。
    ///   - store: 履歴の保管庫。
    /// - Returns: 選ばれたファイルと、履歴で除外した件数。
    static func pick(candidates: [URL],
                            historyID: String,
                            store: ShuffleHistoryStore) -> Draw? {
        guard !candidates.isEmpty else { return nil }
        guard candidates.count > 1 else {
            // 1 曲しかないなら履歴を見る意味がない。記録だけしておく。
            let only = candidates[0]
            store.save(alarmID: historyID, history: [only.lastPathComponent])
            return Draw(picked: only, excludedCount: 0, candidateCount: 1)
        }

        let history = store.load(alarmID: historyID)

        // 候補の半分までしか除外しない。
        // 全部除外すると選べなくなるし、候補が少ないときに履歴が効きすぎて
        // 「毎回同じ 2 曲を往復する」ような偏りが出る。
        let excludeCount = min(history.count, candidates.count / 2)
        let excludeSet = Set(history.prefix(excludeCount))

        let pool = candidates.filter { !excludeSet.contains($0.lastPathComponent) }
        let effective = pool.isEmpty ? candidates : pool

        guard let picked = effective.randomElement() else { return nil }

        var newHistory = [picked.lastPathComponent]
            + history.filter { $0 != picked.lastPathComponent }
        if newHistory.count > maxHistorySize {
            newHistory = Array(newHistory.prefix(maxHistorySize))
        }
        store.save(alarmID: historyID, history: newHistory)

        return Draw(picked: picked,
                    excludedCount: excludeCount,
                    candidateCount: candidates.count)
    }

    /// フォルダから候補を集める。
    ///
    /// - Parameters:
    ///   - directory: 走査するフォルダ。
    ///   - extensions: 小文字の拡張子。空なら拡張子で絞らない。
    ///   - recursive: サブフォルダも見るか。
    static func gatherCandidates(in directory: URL,
                                        extensions: Set<String>,
                                        recursive: Bool) -> [URL] {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else { return [] }

        var result: [URL] = []

        func accept(_ url: URL) {
            guard !url.lastPathComponent.hasPrefix(".") else { return }
            if !extensions.isEmpty,
               !extensions.contains(url.pathExtension.lowercased()) { return }
            result.append(url)
        }

        if recursive {
            guard let enumerator = fm.enumerator(
                at: directory,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]) else { return [] }
            for case let url as URL in enumerator {
                guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey]),
                      values.isRegularFile == true else { continue }
                accept(url)
            }
        } else {
            let names = (try? fm.contentsOfDirectory(atPath: directory.path)) ?? []
            for name in names {
                let url = directory.appendingPathComponent(name)
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: url.path, isDirectory: &isDir),
                      !isDir.boolValue else { continue }
                accept(url)
            }
        }

        return result.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
