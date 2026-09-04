//
//  LCGuestHandler.swift
//  AlarmHandler
//
//  LiveContainer のプロセスに読み込ませるエントリポイント。
//
//  ── 経緯 ────────────────────────────────────────────────────────
//
//  LiveContainer 内では、停止ボタンからゲストの**プロセス**を起こせない。
//  3 通り試して全滅した (2026-09-04 実測)。
//
//    | 呼び出し元 | 実行権 | 結果 |
//    |---|---|---|
//    | マルチタスク (前面) | 前面 | ○ |
//    | LiveActivityIntent の背景起動 | 弱い | × |
//    | BGContinuedProcessingTask のハンドラ | 正式なアサーション | × |
//
//  3 つ目が決め手で、アサーションの問題ではなく「前面かどうか」が条件。
//
//  代わりに **LiveContainer のプロセスにこの dylib を読み込ませる**。
//  本家にも前例がある (LiveProcess の customPayloadDylib、LCLoadTweaksToSelf)。
//
//  ── LiveContainer が知ること ────────────────────────────────────
//
//  「`RTLD_DEFAULT` からシンボルを引いて呼ぶ」だけ。
//  action と payload の中身は解釈しない。抽選も履歴もアラームも知らない。
//
//  【v48】dylib の読み込みも LiveContainer はしない。
//    既存の Tweaks 機構 (`LCLoadTweaksToSelf`) が担う。
//    ユーザーが「調整をインポート」で Documents/Tweaks に置き、
//    設定「調整を LiveContainer 自身にも注入」を有効にする。
//
//  【v48】シンボル名をアプリ固有にした。`RTLD_DEFAULT` は先勝ちなので、
//    複数のアプリが同じ名前を名乗ると衝突する。
//
//  ── 実行される文脈 (重要) ───────────────────────────────────────
//
//  この関数は **LiveContainer のプロセス**で走る。AlarmClock ではない。
//
//    - `UserDefaults.standard` … LiveContainer の設定が返る
//    - `NSHomeDirectory()`      … LiveContainer のホームが返る
//    - `Bundle.main`            … LiveContainer のバンドル
//
//  自分のコンテナに触るには data で渡されたパスを使う。
//  ただし `NSHomeDirectory()` が LiveContainer のホームであることは
//  **利用できる**。data のパスをそこからの相対で書けば解決できる。
//

import Foundation

/// LiveContainer から `dlsym` で引かれるエントリポイント。
///
/// `@_cdecl` を付けて C のシンボル名を固定する。付けないと Swift の
/// マングル名になり `dlsym` で引けない。
/// `DEAD_CODE_STRIPPING: NO` も同じ理由 (誰も呼ばないので削られる)。
///
/// - Parameters:
///   - action: 何をするか。`"reshuffle"` のみ対応。
///   - payload: JSON。すべてのパスは **LiveContainer のホームからの相対**。
///
///     ```json
///     {
///       "documents": "Documents/Data/Application/<UUID>/Documents",
///       "poolRel":   "AlarmSound",
///       "target":    "Library/Sounds/prepared-XXXX.flac",
///       "historyID": "<alarmID>"
///     }
///     ```
///
/// - Returns: 0 成功 / 1 payload 不正 / 2 対象なし / 3 置き換え失敗
@_cdecl("AlarmClockGuestPerform")
public func AlarmClockGuestPerform(
    _ action: UnsafePointer<CChar>?,
    _ payload: UnsafePointer<CChar>?
) -> Int32 {
    let actionText = action.map { String(cString: $0) } ?? ""
    let payloadText = payload.map { String(cString: $0) } ?? ""

    // 【v49】入口で必ず 1 行書く。
    //   これが無いと「呼ばれなかった」と「呼ばれたが早期 return した」の
    //   区別がつかない。陽性対照として置いておく。
    HandlerTrace.record("入りました action=\(actionText)")

    guard actionText == "reshuffle" else {
        HandlerTrace.record("未対応の action=\(actionText)")
        return 1
    }

    guard let data = payloadText.data(using: .utf8),
          let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let documentsRel = spec["documents"] as? String, !documentsRel.isEmpty,
          let targetRel = spec["target"] as? String, !targetRel.isEmpty,
          let historyID = spec["historyID"] as? String, !historyID.isEmpty else {
        HandlerTrace.record("payload を読めません: \(payloadText)")
        return 1
    }
    let poolRel = (spec["poolRel"] as? String) ?? ""

    // LiveContainer のホームからの相対パスを解決する。
    // ここが LiveContainer のプロセスであることを逆に利用している。
    let lcHome = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
    let documents = lcHome.appendingPathComponent(documentsRel, isDirectory: true)
    let target = lcHome.appendingPathComponent(targetRel)
    let pool = poolRel.isEmpty
        ? documents
        : documents.appendingPathComponent(poolRel, isDirectory: true)

    let fm = FileManager.default
    guard fm.fileExists(atPath: target.path) else {
        HandlerTrace.record("target がありません: \(targetRel)")
        return 2
    }

    // target と同じ拡張子だけを対象にする。
    // ファイル名を変えずに中身だけ入れ替えるので、拡張子が変わると
    // AlarmKit が読めなくなる。
    let ext = target.pathExtension.lowercased()
    let candidates = SoundShuffle.gatherCandidates(
        in: pool, extensions: ext.isEmpty ? [] : [ext], recursive: true)
    guard !candidates.isEmpty else {
        HandlerTrace.record("候補が 0 件です pool=\(poolRel.isEmpty ? "(Documents)" : poolRel) ext=\(ext)")
        return 2
    }

    let store = ShuffleHistoryStore(documents: documents)
    guard let draw = SoundShuffle.pick(candidates: candidates,
                                       historyID: historyID,
                                       store: store) else {
        HandlerTrace.record("抽選できませんでした")
        return 2
    }

    // 一時ファイル経由で原子的に置き換える。
    // 鳴動中に差し替えても現在の再生は壊れないことは実測済みだが、
    // 途中で落ちたときに壊れたファイルを残さないようにする。
    let tmp = target.deletingLastPathComponent()
        .appendingPathComponent(".alarm-tmp-\(UUID().uuidString).\(ext)")
    do {
        try? fm.removeItem(at: tmp)
        try fm.copyItem(at: draw.picked, to: tmp)
        _ = try fm.replaceItemAt(target, withItemAt: tmp)
    } catch {
        try? fm.removeItem(at: tmp)
        HandlerTrace.record("置き換えに失敗: \(error.localizedDescription)")
        return 3
    }

    HandlerTrace.record(
        "差し替えました \(target.lastPathComponent) <- \(draw.picked.lastPathComponent) "
        + "(候補 \(draw.candidateCount) 曲中、履歴により \(draw.excludedCount) 曲を除外)"
    )
    return 0
}

/// 記録先。
///
/// この dylib は LiveContainer のプロセスで走るので、`NSHomeDirectory()` は
/// LiveContainer のホーム。そこの `Documents/lc-guest-intent.log` に追記すれば、
/// ホスト側のログと同じファイルに時系列で並ぶ。
///
/// LiveContainer は `UIFileSharingEnabled = true` なので
/// 「ファイル」アプリ > LiveContainer からそのまま読める。
enum HandlerTrace {

    static func record(_ message: String) {
        NSLog("[AlarmHandler] %@", message)

        let documents = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Documents", isDirectory: true)
        let url = documents.appendingPathComponent("lc-guest-intent.log")

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let line = "[\(formatter.string(from: Date()))] AlarmHandler: \(message)\n"

        guard let data = line.data(using: .utf8) else { return }
        try? FileManager.default.createDirectory(
            at: documents, withIntermediateDirectories: true)

        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
        } else {
            try? data.write(to: url)
        }
    }
}
