//
//  LCGuestIntentStub.swift
//  AlarmClock
//
//  LiveContainer が宣言している `LCGuestIntent` と**構造が一致する**スタブ。
//
//  ── なぜ要るのか ────────────────────────────────────────────────
//
//  ゲストアプリの App Intents は installd に登録されないため、自前の型を
//  `AlarmKit` の `stopIntent` に渡しても解決されない (v31〜v32 実測)。
//
//  一方、**ホスト (LiveContainer) が宣言した型**は登録されている。
//  構造の一致するスタブを渡すと、システムはホスト側の実体を解決して実行する
//  (2026-09-04 実測)。
//
//  一致が必要なのは `persistentIdentifier` **だけ**。Swift のマングル名は
//  違っていてよい (ホスト = `LiveContainer`、こちら = `AlarmClock`)。
//
//  ── 環境によって解決先が変わる ──────────────────────────────────
//
//  【v50】直インストールでは**この型が解決されて実行される**。
//  自分のバンドルの Metadata.appintents に登録されているため。
//
//    | 環境 | 解決先 |
//    |---|---|
//    | 直インストール | このアプリ自身 |
//    | 素の LiveContainer | どこにも無い (= 再現したい問題) |
//    | パッチ版 LiveContainer | LiveContainer の同名 Intent → dylib |
//
//  `persistentIdentifier` は installd 内でアプリごとに独立しているので、
//  LiveContainer と AlarmClock の両方が同じ値を名乗っても衝突しない。
//
//  どの経路でも最終的に `AlarmHandlerCore.perform` に入るので、
//  **環境による動作の差は出ない**。
//
//  ── @Parameter は完全一致させること ─────────────────────────────
//
//  名前・型・宣言順のいずれかがずれるとデコードに失敗する可能性がある。
//

import AppIntents
import Foundation

@available(iOS 17.0, *)
struct LCGuestIntent: LiveActivityIntent {

    static var title: LocalizedStringResource = "LiveContainer Guest Action"

    static var isDiscoverable: Bool = false
    static var openAppWhenRun: Bool = false

    /// LiveContainer 側と同一の値。ここが解決の鍵。
    static var persistentIdentifier: String { "com.kdt.livecontainer.guestIntent" }

    /// 呼び出す C シンボル名。
    /// `Handler/LCGuestHandler.swift` の `@_cdecl` と一致させること。
    @Parameter(title: "Handler Symbol")
    var handler: String

    /// ゲストに渡す任意の文字列。LiveContainer は中身を解釈しない。
    @Parameter(title: "Action")
    var action: String

    /// ゲストに渡す任意の文字列。LiveContainer は中身を解釈しない。
    @Parameter(title: "Payload")
    var payload: String

    init() {
        self.handler = ""
        self.action = ""
        self.payload = ""
    }

    init(handler: String, action: String = "", payload: String = "") {
        self.handler = handler
        self.action = action
        self.payload = payload
    }

    /// 【v50】直インストール時はここが走る。
    ///
    /// LiveContainer 内ではこの型ではなくホスト側の同名 Intent が解決されるので、
    /// ここは呼ばれない。どちらの経路でも `AlarmHandlerCore.perform` に入るので、
    /// **環境による動作の差は出ない**。
    ///
    ///   | 環境 | 解決先 | 走るコード |
    ///   |---|---|---|
    ///   | 直インストール | このアプリ自身 | ここ → AlarmHandlerCore |
    ///   | 素の LiveContainer | どこにも無い | **何も走らない** |
    ///   | パッチ版 LiveContainer | LC の LCGuestIntent | dylib → AlarmHandlerCore |
    func perform() async throws -> some IntentResult {
        let result = AlarmHandlerCore.perform(action: action, payload: payload)
        EventLog.log(.stopPressed, alarmIDString: payload,
                     message: "LCGuestIntent (アプリ内) を実行 result=\(result)")
        return .result()
    }
}
