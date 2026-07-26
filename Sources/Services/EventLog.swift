//
//  EventLog.swift
//  AlarmClock
//
//  「いつ・何が・どのアラームに対して起きたか」を時系列で記録する診断用ログ。
//
//  目的:
//    アラームが鳴らない / エラーが出るといった不具合は、
//    「作成 → 登録 → 発火 → 停止 → 再登録」のどの段階で崩れたのかが
//    分からないと原因を特定できない。ID とタイムスタンプを突き合わせられるよう、
//    主要な操作をすべて記録する。
//
//  設計:
//    - `enum` の static メソッドとして実装し、どこからでも呼べるようにする。
//      (App Intent は @MainActor でない文脈から実行されるため、
//       アクター隔離された singleton にすると呼び出しづらい)
//    - 保存先は UserDefaults。App Intent とアプリ本体で同じ UserDefaults を
//      参照できることは、既存の PendingSnoozeAlarmID の受け渡しで確認済み。
//    - 件数が増え続けないよう上限を設け、古いものから捨てる。
//    - Documents 配下にテキストとして書き出せるようにし、
//      「ファイル」アプリや共有シートから取り出せるようにする。
//

import Foundation

/// ログ 1 件分。
struct LogEntry: Codable, Identifiable {
    var id: UUID
    var timestamp: Date
    /// 出来事の種類 (EventLog.Category.rawValue)
    var category: String
    /// 関連するアラーム ID (無い場合は nil)
    var alarmID: String?
    /// 補足情報
    var message: String

    init(category: String, alarmID: String?, message: String) {
        self.id = UUID()
        self.timestamp = Date()
        self.category = category
        self.alarmID = alarmID
        self.message = message
    }
}

enum EventLog {

    /// 出来事の種類。UI での色分けや絞り込みにも使う。
    enum Category: String {
        case bootstrap   = "起動"
        case create      = "作成"
        case update      = "編集"
        case delete      = "削除"
        case toggle      = "切替"
        case scheduleOK  = "登録成功"
        case scheduleNG  = "登録失敗"
        case cancel      = "登録解除"
        case stopPressed = "停止ボタン"
        case snoozePress = "スヌーズボタン"
        case reshuffle   = "再抽選"
        case purge       = "取り残し削除"
        case sound       = "音源"
    }

    private static let storageKey = "EventLog.entries"
    private static let maxEntries = 600

    /// 同時書き込みでログが壊れないようにするためのロック。
    private static let lock = NSLock()

    // MARK: - 記録

    /// 出来事を 1 件記録する。
    /// - Parameters:
    ///   - category: 出来事の種類
    ///   - alarmID: 対象のアラーム ID (あれば)
    ///   - message: 補足情報 (時刻や設定値など、後から追える情報を入れる)
    static func log(_ category: Category, alarmID: UUID? = nil, message: String = "") {
        log(category, alarmIDString: alarmID?.uuidString, message: message)
    }

    /// ID を文字列で受け取る版 (App Intent は String で ID を持つため)。
    static func log(_ category: Category, alarmIDString: String?, message: String = "") {
        let entry = LogEntry(
            category: category.rawValue,
            alarmID: alarmIDString,
            message: message
        )

        lock.lock()
        defer { lock.unlock() }

        var all = loadRaw()
        all.append(entry)
        if all.count > maxEntries {
            all.removeFirst(all.count - maxEntries)
        }
        saveRaw(all)

        debugPrint("[\(category.rawValue)] \(alarmIDString.map { String($0.prefix(8)) } ?? "-") \(message)")
    }

    // MARK: - 取得

    /// 記録されているログを新しい順で返す。
    static func entries() -> [LogEntry] {
        loadRaw().reversed()
    }

    /// 記録件数。
    static func count() -> Int {
        loadRaw().count
    }

    /// すべて消す。
    static func clear() {
        lock.lock()
        defer { lock.unlock() }
        UserDefaults.standard.removeObject(forKey: storageKey)
    }

    // MARK: - 書き出し

    /// ログを人が読めるテキストに整形する (古い順)。
    static func exportText() -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "ja_JP")
        df.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"

        var lines: [String] = []
        lines.append("AlarmClock 診断ログ")
        lines.append("書き出し日時: \(df.string(from: Date()))")
        lines.append("件数: \(count())")
        lines.append(String(repeating: "-", count: 60))

        for e in loadRaw() {
            let time = df.string(from: e.timestamp)
            let idPart = e.alarmID ?? "-"
            lines.append("\(time)  [\(e.category)]  id=\(idPart)")
            if !e.message.isEmpty {
                lines.append("    \(e.message)")
            }
        }

        return lines.joined(separator: "\n")
    }

    /// ログを Documents 配下にテキストファイルとして書き出し、その URL を返す。
    ///
    /// Documents に置くのは、Info.plist で UIFileSharingEnabled を有効にしているため
    /// 「ファイル」アプリからも直接開けるようにするため。
    /// 併せて共有シート (ShareLink) からも渡せる。
    static func writeExportFile() -> URL? {
        let fm = FileManager.default
        guard let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }

        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.dateFormat = "yyyyMMdd-HHmmss"
        let name = "AlarmClock-log-\(df.string(from: Date())).txt"
        let url = docs.appendingPathComponent(name)

        do {
            try exportText().data(using: .utf8)?.write(to: url)
            return url
        } catch {
            debugPrint("[EventLog] export failed: \(error)")
            return nil
        }
    }

    // MARK: - 内部

    private static func loadRaw() -> [LogEntry] {
        guard let data = UserDefaults.standard.data(forKey: storageKey),
              let list = try? JSONDecoder().decode([LogEntry].self, from: data) else {
            return []
        }
        return list
    }

    private static func saveRaw(_ entries: [LogEntry]) {
        if let data = try? JSONEncoder().encode(entries) {
            UserDefaults.standard.set(data, forKey: storageKey)
        }
    }
}
