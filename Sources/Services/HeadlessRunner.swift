//
//  HeadlessRunner.swift
//  AlarmClock
//
//  LiveProcess 経由で「画面を出さずに」起動されたときの処理。
//
//  起点 (v42 で変更):
//    LiveContainer が宣言した LCGuestIntent が停止ボタンから解決され、
//    その perform() が LiveProcess.appex 経由でこのアプリを起こす。
//
//      [AlarmKit のアラート] 停止ボタン
//        ↓ システムが LCGuestIntent を解決 (画面は点かない)
//      LiveContainer のプロセスで perform()
//        ↓ NSExtension
//      LiveProcess.appex
//        ↓
//      このアプリが別プロセスで起動 → App.init() → ここ
//        ↓
//      音源を差し替え → exit(0)
//
//    アプリを開かなくても、鳴らして止めるたびに次回の曲が変わる。
//
//  v41 までの経緯:
//    「ゲストが宣言した App Intents は installd に登録されないので、
//    停止ボタンからは何も起動できない」と結論していた (v31〜v32 の実測)。
//    そのため起点を時刻に変え、ショートカットの自動化から
//    LiveContainer の "Probe Headless Launch" を叩いていた。
//
//    2026-09-04 に、この結論が「**ゲストが宣言した型では**」という
//    条件付きだったことが分かった。ホスト (LiveContainer) が宣言した
//    LiveActivityIntent をゲストから渡せば解決される。
//    → ショートカットの自動化も Probe Headless Launch も不要になった。
//
//  マルチタスクとの区別:
//    マルチタスクも LiveProcess を使うが、あちらはホストがシーンを繋いで
//    ずっと表示し続ける。**そちらで exit(0) してはいけない。**
//    そこで「一定時間待ってもシーンが繋がらなければヘッドレス」と判定する。
//
//  必要な前提 (LiveContainer 側):
//    - Library/Sounds のブックマークが渡されていること
//      AlarmKit のカスタム音源はホストのコンテナ配下から読まれるため、
//      そこへの書き込み権限がないと差し替えられない
//
import Foundation

enum HeadlessRunner {

    /// シーンが接続されたか。AlarmListView が .task で立てる。
    /// マルチタスク表示中に exit(0) しないための目印。
    private static let sceneLock = NSLock()
    private static var sceneConnectedFlag = false

    static func markSceneConnected() {
        sceneLock.lock(); sceneConnectedFlag = true; sceneLock.unlock()
    }

    private static var sceneConnected: Bool {
        sceneLock.lock(); defer { sceneLock.unlock() }
        return sceneConnectedFlag
    }

    /// シーンが繋がるのを待つ秒数。これを過ぎたらヘッドレスとみなす。
    private static let sceneGraceSeconds: TimeInterval = 6

    /// 処理全体に使ってよい秒数。App Intent には実行時間の制限があるため、
    /// 長く粘らずに切り上げる (60 秒の観測は実際にタイムアウトした)。
    private static let workTimeoutSeconds: TimeInterval = 12

    // MARK: - 入口

    /// `App.init()` から呼ぶ。LiveProcess 経由でなければ何もしない。
    static func runIfNeeded() {
        guard RuntimeEnvironment.isLiveProcess else { return }

        LaunchTrace.record("headless-start")

        // 1. まず書き込み可否だけを確かめる (これが今回の主目的)
        let soundsDir = RuntimeEnvironment.alarmKitSoundsDirectory
        let probe = soundsDir.appendingPathComponent(".lc-write-probe")
        var writable = false
        var writeError = "(なし)"
        do {
            try FileManager.default.createDirectory(at: soundsDir, withIntermediateDirectories: true)
            try Data([0x41]).write(to: probe)
            try? FileManager.default.removeItem(at: probe)
            writable = true
        } catch {
            writeError = "\((error as NSError).domain) code=\((error as NSError).code)"
        }
        LaunchTrace.record("sounds-writable=\(writable ? "はい" : "いいえ")  err=\(writeError)  path=\(soundsDir.path)")

        // 2. 書けるなら実際に差し替えてみる
        if writable {
            runRefresh()
        } else {
            LaunchTrace.record("差し替えをスキップ (Library/Sounds に書けないため)")
            LaunchTrace.record("→ LiveContainer 側で Library/Sounds のブックマークを追加する必要があります")
        }

        // 3. シーンが繋がらなければ自分で終了する
        scheduleSelfTerminationIfHeadless()
    }

    // MARK: - 差し替え

    /// 有効なランダム抽選アラームの音源を差し替える。
    ///
    /// `perform()` の時間制限があるので、待ち時間に上限を設ける。
    private static func runRefresh() {
        let items = AlarmStorage.shared.load()
            .filter { $0.enabled && $0.soundSourceMode == .random }

        guard !items.isEmpty else {
            LaunchTrace.record("差し替え対象なし (有効なランダム抽選アラームが 0 件)")
            return
        }

        let semaphore = DispatchSemaphore(value: 0)
        Task {
            var changed = 0
            for item in items {
                if let result = await SoundLibraryService.shared.refreshPreparedSound(
                    alarmID: item.id,
                    historyKeyID: item.snoozeSourceID,
                    useFolder: item.randomSourceUseFolder,
                    folderRelPath: item.folderRelPath,
                    libraryFileNames: item.randomSourceLibraryFileNames
                ) {
                    changed += 1
                    LaunchTrace.record("差し替え: \(result.sourceName) [.\(result.deliveredExtension)] (候補 \(result.candidateCount) 曲)")
                }
            }
            LaunchTrace.record("差し替え完了: \(changed)/\(items.count) 件")
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + workTimeoutSeconds) == .timedOut {
            LaunchTrace.record("差し替えがタイムアウトしました (\(Int(workTimeoutSeconds)) 秒)")
        }
    }

    // MARK: - 自己終了

    /// 一定時間待ってもシーンが繋がらなければ `exit(0)` する。
    ///
    /// マルチタスク表示中は AlarmListView が `markSceneConnected()` を呼ぶので、
    /// そちらでは終了しない。
    private static func scheduleSelfTerminationIfHeadless() {
        DispatchQueue.global().asyncAfter(deadline: .now() + sceneGraceSeconds) {
            if sceneConnected {
                LaunchTrace.record("シーンが接続されたので終了しません (マルチタスク表示)")
                return
            }
            LaunchTrace.record("ヘッドレスと判断して終了します exit(0)")
            exit(0)
        }
    }
}
