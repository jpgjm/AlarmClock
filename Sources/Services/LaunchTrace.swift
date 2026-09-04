//
//  LaunchTrace.swift
//  AlarmClock
//
//  起動と、ヘッドレス実行の記録。
//
//  なぜ必要か:
//    LiveContainer 内で LCGuestIntent からヘッドレス起動されたとき、
//    画面が出ないので何が起きたか確かめる手段がない。
//    EventLog はアプリ内でしか見られないうえ、ヘッドレス起動では
//    そもそもアプリを開かない。
//
//    そこでプロセスの外 (ファイル) に記録を残す。
//    ヘッドレス実行が成功したか、音源が差し替わったかを、
//    ファイルアプリから直接確認できる。
//
//  書き込み先は 2 箇所:
//    guest … ゲスト自身の Documents。ヘッドレスでも必ず書ける
//    host  … ホストの Documents。ファイルアプリから見やすいが
//            ヘッドレスでは EPERM で書けない
//
//    LiveContainer がヘッドレス起動時に渡すブックマークは
//    「アプリ / コンテナ / Tweaks / Library-Sounds」の 4 つで、
//    ホストの Documents はその外側にあるため。
//
//  ヘッドレスで書けた記録の場所:
//    ファイル > LiveContainer > Data > Application > <コンテナUUID>
//             > Documents > AlarmClockLaunched.txt
//
//    コンテナ UUID は診断画面に表示される。
//
//  通常インストールでは 2 箇所が同じ場所を指すので 1 つになる。
//
import Foundation

enum LaunchTrace {

    /// 痕跡ファイルの名前。ファイルアプリで探しやすいよう素直な名前にする。
    private static let fileName = "AlarmClockLaunched.txt"

    /// 保持する行数。これを超えたら古いものから捨てる。
    private static let maxLines = 50

    /// 痕跡の書き込み先。
    struct Candidate: Identifiable, Hashable {
        /// "guest" か "host"
        let label: String
        let url: URL
        var id: String { url.path }

        /// 画面に出す名前。
        var displayName: String {
            label == "guest" ? "ゲストのコンテナ" : "ホストの Documents"
        }
    }

    /// 痕跡の書き込み先の候補。
    ///
    /// 【v36】2 箇所に書く。ヘッドレス起動では片方しか書けないため。
    ///
    ///   1. ゲスト自身のコンテナ ($HOME/Documents)
    ///      LiveContainer がヘッドレス起動時に渡すブックマークに含まれるので、
    ///      サンドボックス的に書ける
    ///   2. ホストの Documents ($LC_HOME_PATH/Documents)
    ///      ファイルアプリの「LiveContainer」直下から直接見える
    ///
    ///   通常インストールでは 1 と 2 が同じ場所を指すので、1 つだけ返す。
    static var candidateURLs: [Candidate] {
        let guestDocs = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
        var result = [Candidate(label: "guest", url: guestDocs.appendingPathComponent(fileName))]

        if let hostHome = ProcessInfo.processInfo.environment["LC_HOME_PATH"] {
            let hostURL = URL(fileURLWithPath: hostHome, isDirectory: true)
                .appendingPathComponent("Documents", isDirectory: true)
                .appendingPathComponent(fileName)
            if hostURL.standardizedFileURL != result[0].url.standardizedFileURL {
                result.append(Candidate(label: "host", url: hostURL))
            }
        }
        return result
    }

    /// 表示や読み取りに使う代表的な 1 つ。
    /// ホスト側があればそちら (ファイルアプリから見えるため)。
    static var fileURL: URL {
        let candidates = candidateURLs
        return candidates.last?.url ?? candidates[0].url
    }

    /// 起動したことを記録する。
    ///
    /// `App.init()` から呼ぶ。シーンの接続を待たないので、
    /// ヘッドレス起動でも走る。
    ///
    /// - Parameter reason: 何をきっかけに走ったか (例 "init")
    static func record(_ reason: String) {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        // ヘッドレス起動かどうかの手がかりになる情報を並べる。
        //   isLiveProcess … LiveProcess.appex 経由なら、実行ファイルのパスに
        //                   PlugIns/LiveProcess.appex が含まれる
        let execPath = Bundle.main.executablePath ?? "(不明)"
        let viaLiveProcess = execPath.contains("LiveProcess.appex")
            || ProcessInfo.processInfo.environment["LP_HOME_PATH"] != nil

        let line = [
            f.string(from: Date()),
            "reason=\(reason)",
            "pid=\(getpid())",
            "env=\(ProcessInfo.processInfo.environment["LC_HOME_PATH"] != nil ? "LiveContainer" : "通常")",
            "liveProcess=\(viaLiveProcess ? "はい" : "いいえ")",
            "bundle=\(Bundle.main.bundleIdentifier ?? "?")",
        ].joined(separator: "  ")

        append(line)
        debugPrint("[LaunchTrace] \(line)")
    }

    /// 最後の 1 行を返す (診断画面用)。無ければ nil。
    ///
    /// 【v36】全候補のうち、最も新しい記録を持つものを採用する。
    ///   ヘッドレスでは guest 側にしか書けないので、そちらを拾う必要がある。
    static func lastLine() -> String? {
        var best: (date: Date, line: String)? = nil
        for candidate in candidateURLs {
            guard let text = try? String(contentsOf: candidate.url, encoding: .utf8),
                  let last = text.split(separator: "\n", omittingEmptySubsequences: true).last
            else { continue }
            let attrs = try? FileManager.default.attributesOfItem(atPath: candidate.url.path)
            let date = (attrs?[.modificationDate] as? Date) ?? Date.distantPast
            if best == nil || date > best!.date {
                best = (date, "[\(candidate.label)] \(last)")
            }
        }
        return best?.line
    }

    /// 記録されている行数 (診断画面用)。全候補の最大値。
    static func lineCount() -> Int {
        var maxCount = 0
        for candidate in candidateURLs {
            guard let text = try? String(contentsOf: candidate.url, encoding: .utf8) else { continue }
            maxCount = max(maxCount, text.split(separator: "\n", omittingEmptySubsequences: true).count)
        }
        return maxCount
    }

    /// 痕跡を消す (診断画面用)。全候補を消す。
    static func clear() {
        for candidate in candidateURLs {
            try? FileManager.default.removeItem(at: candidate.url)
        }
    }

    // MARK: - 内部

    /// 全候補に追記する。行数が上限を超えたら古いものから捨てる。
    ///
    /// 起動のたびに呼ばれるので、失敗しても絶対に落ちないようにする。
    /// (記録のために本体が落ちては本末転倒)
    ///
    /// 【v36】書けた / 書けなかった候補を行の末尾に記録する。
    ///   ヘッドレスでは host 側が書けないはずなので、
    ///   その場合 guest 側の行に `host=失敗` が残る。
    private static func append(_ line: String) {
        let candidates = candidateURLs
        var results: [String] = []
        var succeeded: [Candidate] = []

        // まず全部に書いてみて、成否を集める
        for candidate in candidates {
            if write(line: line, to: candidate.url) {
                results.append("\(candidate.label)=OK")
                succeeded.append(candidate)
            } else {
                results.append("\(candidate.label)=失敗")
            }
        }

        // 書けた先に「どこに書けたか」を追記する
        guard !succeeded.isEmpty else { return }
        let detail = "    書き込み: \(results.joined(separator: "  "))"
        for candidate in succeeded {
            _ = write(line: detail, to: candidate.url)
        }
    }

    /// 1 行追記する。成功なら true。
    private static func write(line: String, to url: URL) -> Bool {
        var lines: [String] = []
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        }
        lines.append(line)
        if lines.count > maxLines {
            lines = Array(lines.suffix(maxLines))
        }
        do {
            try (lines.joined(separator: "\n") + "\n")
                .write(to: url, atomically: true, encoding: .utf8)
            return true
        } catch {
            debugPrint("[LaunchTrace] 書き込み失敗 \(url.path): \(error)")
            return false
        }
    }
}
