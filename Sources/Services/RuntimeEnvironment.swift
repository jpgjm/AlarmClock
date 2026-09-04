//
//  RuntimeEnvironment.swift
//  AlarmClock
//
//  「このアプリが今どこで動いているか」を判定し、それに応じたパス解決を提供する。
//
//  背景:
//    LiveContainer (以下 LC) はゲストアプリを **ホストのプロセス内で** 動かす
//    アプリランチャー。ゲストは HOME や NSBundle をフックで差し替えられており、
//    アプリから見ると通常のインストールと区別がつかない。
//
//    しかし AlarmKit は「システムデーモンがアプリの代理で鳴らす」フレームワークで、
//    デーモンから見た登録者は **LiveContainer** になる。この食い違いが原因で、
//    素のままでは以下が壊れる。
//
//      1. カスタム音源のパス
//         ゲストが Library/Sounds に書いてもデーモンはホストの実コンテナを見る
//         → ここで LC_HOME_PATH を使って書き込み先を切り替える
//
//      2. App Intents (停止 / スヌーズ)
//         ゲストの Intent 型は installd に登録されないため解決できない
//         → AlarmService 側で stopIntent / secondaryIntent を nil にする
//
//      3. BGTaskScheduler
//         BGTaskSchedulerPermittedIdentifiers はホストの Info.plist が使われ、
//         このアプリの識別子は入っていない
//         → AlarmClockApp 側で register をスキップする
//
//  判定方法:
//    LC は HOME を差し替える *前に*、本来の HOME を環境変数に退避している。
//
//      // LiveContainer/LCBootstrap.m
//      setenv("LC_HOME_PATH", getenv("HOME"), 0);
//
//    したがって `LC_HOME_PATH` の有無がそのまま「LC 内かどうか」の判定になる。
//    通常のインストールではこの環境変数は存在しない。
//

import Foundation

/// 実行環境の判定と、環境依存のパス解決。
enum RuntimeEnvironment {

    /// LiveContainer が退避しているホスト本来の HOME を指す環境変数名。
    private static let lcHomePathKey = "LC_HOME_PATH"

    /// LiveContainer のゲストとして動いているか。
    ///
    /// 一度決まれば変わらないので評価結果を保持する。
    static let isLiveContainer: Bool = {
        ProcessInfo.processInfo.environment[lcHomePathKey] != nil
    }()

    /// LiveProcess.appex 経由で起動されたか。
    ///
    /// マルチタスクとヘッドレス起動の両方でこれが true になる。
    /// 「画面を出さない起動か」を判定するには、シーンが接続されるかを
    /// 別途待つ必要がある (HeadlessRunner がやっている)。
    static let isLiveProcess: Bool = {
        if ProcessInfo.processInfo.environment["LP_HOME_PATH"] != nil { return true }
        return (Bundle.main.executablePath ?? "").contains("LiveProcess.appex")
    }()

    /// LiveContainer 本体 (ホスト) の実コンテナのパス。
    /// 通常インストール時は nil。
    static let hostHomePath: String? = {
        ProcessInfo.processInfo.environment[lcHomePathKey]
    }()

    // MARK: - パス解決

    /// AlarmKit がカスタム音源を探索する `Library/Sounds/` の URL。
    ///
    /// - 通常インストール: 自分のコンテナの `Library/Sounds/`
    /// - LiveContainer 内: **ホストの実コンテナ**の `Library/Sounds/`
    ///
    /// LC 内で自分のコンテナに置いてしまうと、鳴動時にデーモンが見つけられず
    /// 黙ってシステム標準音にフォールバックする (エラーにもならないので気付きにくい)。
    ///
    /// なお LC 内では**全ゲストアプリがこのフォルダを共有する**ことになる。
    /// このアプリが置くファイルは UUID 由来の名前 (`prepared-{alarmID}.{ext}` や
    /// インポート時の `{UUID}.{ext}`) なので実質衝突しないが、
    /// フォルダ内の全削除のような操作は行わないこと。
    static var alarmKitSoundsDirectory: URL {
        let libraryURL: URL
        if let hostHome = hostHomePath {
            libraryURL = URL(fileURLWithPath: hostHome, isDirectory: true)
                .appendingPathComponent("Library", isDirectory: true)
        } else {
            libraryURL = FileManager.default
                .urls(for: .libraryDirectory, in: .userDomainMask)
                .first!
        }
        return libraryURL.appendingPathComponent("Sounds", isDirectory: true)
    }

    /// 抽選元の音源を置くフォルダ (`Documents/AlarmSound/`)。
    ///
    /// **ここは LiveContainer 内でも差し替えない。** 自分の Documents のままでよい。
    /// `prepareAlarmSound()` がこのフォルダを走査するのはアプリ自身の処理であって、
    /// システムデーモンは関与しないため、HOME が差し替わっていても問題なく読める。
    ///
    /// 差し替えが要るのは `alarmKitSoundsDirectory` の方だけ。あちらは
    /// 鳴動時にデーモンが読みに行くので、ホストのコンテナである必要がある。
    static var randomSourceDirectory: URL {
        FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
            .appendingPathComponent("AlarmSound", isDirectory: true)
    }

    // MARK: - LiveContainer にゲスト自身を指し示すための値

    /// LiveContainer から見た自分の **バンドルフォルダ名**。
    ///
    /// `LCGuestIntent` の `bundleId` に渡す値。bundle ID ではない。
    /// LiveContainer は `<LC_HOME_PATH>/Documents/Applications/<この名前>` を探す。
    /// 通常は末尾に `.app` が付く (例 `com.example.alarmclock.app`)。
    ///
    /// LiveContainer 内ではゲストの `Bundle.main` が実際のバンドルを指しているので、
    /// そのパスの末尾がそのままフォルダ名になる。
    static var guestBundleFolderName: String {
        Bundle.main.bundleURL.lastPathComponent
    }

    /// LiveContainer から見た自分の **コンテナフォルダ名** (UUID)。
    ///
    /// `LCGuestIntent` の `container` に渡す値。
    /// 自分の Documents は
    ///   `<LC_HOME_PATH>/Documents/Data/Application/<UUID>/Documents`
    /// にあるので、その 1 つ上のフォルダ名を取ればよい。
    ///
    /// 通常インストール時は意味を持たないので nil を返す。
    static var guestContainerName: String? {
        guard isLiveContainer else { return nil }
        guard let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        let name = documents.deletingLastPathComponent().lastPathComponent
        return name.isEmpty ? nil : name
    }

    /// LiveContainer のホームからの相対パス。届かない場所なら nil。
    ///
    /// `LCGuestIntent` の payload に載せるパスは、すべてこの形式で渡す。
    /// LiveContainer 側は自分の `NSHomeDirectory()` に結合して解決する。
    ///
    /// 通常インストール時は `hostHomePath` が nil なので常に nil を返す。
    static func lcRelativePath(for url: URL) -> String? {
        guard let hostHome = hostHomePath else { return nil }
        let target = normalized(url.standardizedFileURL.path)
        let root = normalized(hostHome)
        guard target.hasPrefix(root + "/") else { return nil }
        return String(target.dropFirst(root.count + 1))
    }

    // MARK: - ファイルアプリ上の表示パス

    /// 「ファイル」アプリでたどれる表示パスに変換する。たどれない場所なら nil。
    ///
    /// iOS が「ファイル」アプリに公開するのは、`UIFileSharingEnabled` が有効な
    /// アプリの **Documents フォルダだけ**。Library 配下は公開されない。
    ///
    /// LiveContainer 内では、公開されるのは **ホスト (LiveContainer) の Documents** で、
    /// ゲストのコンテナはその配下の `Data/Application/{ゲストUUID}/` に置かれている。
    ///
    /// ```
    /// ファイル > このデバイス内 > LiveContainer
    ///   └ Data/Application/{ゲストUUID}/Documents/AlarmSound/   ← 抽選元
    /// ```
    ///
    /// よくある誤解として、「ファイル > LiveContainer > Library/Sounds」を
    /// 作ってそこに置いても鳴らない。これはホストの *Documents の中の*
    /// `Library/Sounds` であって、AlarmKit が読む `<ホスト>/Library/Sounds` とは別物。
    /// 後者は Documents の外にあるので、ファイルアプリからは到達できない
    /// (アプリが自動でコピーするので、手で置く必要もない)。
    static func filesAppPath(for url: URL) -> String? {
        // Documents の公開名。LiveContainer 内ではホストの名前になる。
        let visibleRootName = isLiveContainer ? "LiveContainer" : "Alarm Clock"

        // ファイルアプリに公開されている実フォルダ。
        let exposedDocuments: String
        if let hostHome = hostHomePath {
            exposedDocuments = hostHome + "/Documents"
        } else {
            exposedDocuments = FileManager.default
                .urls(for: .documentDirectory, in: .userDomainMask)
                .first!.path
        }

        let target = normalized(url.path)
        let root = normalized(exposedDocuments)

        guard target == root || target.hasPrefix(root + "/") else {
            return nil
        }
        let relative = String(target.dropFirst(root.count))
        return visibleRootName + relative
    }

    /// `/private/var/...` と `/var/...` を同一視するためにパスを正規化する。
    /// (`/var` は `/private/var` へのシンボリックリンクなので、
    ///  どちらの表記で来ても比較できるようにしておく)
    private static func normalized(_ path: String) -> String {
        var p = path
        if p.hasPrefix("/private/var/") {
            p.removeFirst("/private".count)
        }
        while p.count > 1 && p.hasSuffix("/") {
            p.removeLast()
        }
        return p
    }

    // MARK: - 機能の可否

    /// `stopIntent` / `secondaryIntent` に自前の LiveActivityIntent を渡せるか。
    ///
    /// LC 内では false。ゲストアプリの App Intents は installd に登録されないため、
    /// 停止 / スヌーズボタンが押されてもシステムが Intent を解決できない。
    ///
    /// 【v31〜v32 の検証結果 (実測)】
    ///   推論のまま無効化していたので、実際に渡して確かめた。結論は「解決されない」。
    ///
    ///     - `schedule()` は Intent 付きでも **成功する**
    ///       (登録時に解決可能性は検証されていない)
    ///     - `[停止ボタン]` / `[スヌーズボタン]` のログは **一切残らない**
    ///     - `openAppWhenRun = true` にしても **アプリは開かない**
    ///     - スヌーズ (.custom) を押しても **アラートが止まらない**
    ///       ← これが決定的。.custom のスヌーズは Intent 内で stop() を
    ///         呼ばないと鳴り止まないので、鳴り続ける = Intent が走っていない
    ///
    ///   なお停止ボタンでアラートが止まるのは AlarmKit 標準の挙動であって、
    ///   Intent が動いた証拠にはならない。
    ///
    ///   → LC で `.custom` スヌーズを使うと**アラームが止められなくなる**ため、
    ///     false は「機能制限」ではなく「必須の安全策」。
    static var canUseCustomAppIntents: Bool { !isLiveContainer }


    /// BGTaskScheduler にタスクを登録できるか。
    ///
    /// LC 内では false。`BGTaskSchedulerPermittedIdentifiers` はホストの
    /// Info.plist が参照され、このアプリの識別子は含まれていない。
    static var canUseBackgroundTasks: Bool { !isLiveContainer }

    // MARK: - 表示 / ログ用

    /// 診断画面やログに出す 1 行の要約。
    static var summary: String {
        isLiveContainer ? "LiveContainer (ゲスト)" : "通常インストール"
    }

    /// 診断画面で「何が制限されているか」を並べるための一覧。
    /// 通常インストール時は空配列。
    static var limitations: [String] {
        guard isLiveContainer else { return [] }
        return [
            "停止 / スヌーズボタンの Intent が解決されないため、スヌーズは AlarmKit 標準の再鳴動になります (v32 で実測して確認)",
            "停止時の再抽選が走りません。次回の曲はアプリを開いた時に選び直されます",
            "アラート画面とアラーム権限は LiveContainer 名義で表示されます",
            "AlarmKit の登録枠を他のゲストアプリと共有します",
            "タイムゾーン補正のバックグラウンド再チェックが無効です",
        ]
    }
}
