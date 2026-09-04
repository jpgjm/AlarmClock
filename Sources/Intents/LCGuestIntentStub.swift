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
//  ── この型は実行されない ────────────────────────────────────────
//
//  役割は 2 つだけ。
//
//    1. `AlarmConfiguration(stopIntent:)` に渡せる Swift の値を作る
//    2. システムがシリアライズする識別子を、ホスト側の実体と一致させる
//
//  停止ボタンで走るのは LiveContainer 側の `perform()` で、こちらではない。
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

    /// ここは呼ばれない。呼ばれたら「ゲスト側の型が解決された」ことになり、
    /// それはそれで重大な発見なので痕跡だけ残しておく。
    func perform() async throws -> some IntentResult {
        EventLog.log(.stopPressed, alarmIDString: payload,
                     message: "【想定外】ゲスト側スタブの perform() が実行された")
        return .result()
    }
}
