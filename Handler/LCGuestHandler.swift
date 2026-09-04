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

import AlarmKit
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
    return AlarmHandlerCore.perform(action: actionText, payload: payloadText)
}

/// スヌーズの一時アラーム用のメタデータ。
///
/// アプリ本体の `AlarmClockMetadata` は `Sources/` にあり、dylib ターゲットは
/// そちらをコンパイルしないので、ここで最小のものを用意する。
/// 中身は使わないので空でよい。
struct SnoozeMetadata: AlarmMetadata {
    init() {}
}

/// 実装本体。C のエントリと、直インストール時の `LCGuestIntent.perform()` の
/// 両方から呼ばれる。**抽選ルールの入口はここ 1 か所**。
enum AlarmHandlerCore {

    /// - Parameters:
    ///   - action: `"reshuffle"` のみ対応。
    ///   - payload: JSON。**パスはすべて絶対パス**。
    ///
    ///     ```json
    ///     {
    ///       "documents": "/var/mobile/.../Documents",
    ///       "pool":      "/var/mobile/.../Documents/AlarmSound",
    ///       "target":    "/var/mobile/.../Library/Sounds/prepared-XXXX.flac",
    ///       "historyID": "<alarmID>"
    ///     }
    ///     ```
    ///
    /// - Returns: 0 成功 / 1 payload 不正 / 2 対象なし / 3 置き換え失敗
    static func perform(action: String, payload: String) -> Int32 {
        HandlerTrace.record("入りました action=\(action)")
        HandlerTrace.record("  pid=\(getpid()) bundle=\(Bundle.main.bundleIdentifier ?? "(なし)")")

        // 【v50 / 検証】このプロセスから AlarmKit を操作できるか。
        //
        //   dylib は LiveContainer のプロセスで走る。アラームを登録したのも
        //   LiveContainer なので、同一クライアントとして見えるはず。
        //   見えるなら `AlarmManager.shared.stop(id:)` も呼べるので、
        //   スヌーズを `.custom` にできる (v51 の課題)。
        //
        //   件数が 0 なら別クライアント扱いなので `.custom` は諦める。
        //   読み取りだけなので副作用はない。
        probeAlarmKit()

        switch action {
        case "reshuffle":
            break   // 下の共通処理へ

        case "snooze":
            // 【v51】`.custom` では AlarmKit が自動で止めてくれない。
            //   Intent 自身が stop() を呼ばないと鳴り続ける。
            //
            //   このプロセスから AlarmKit が見えることは実測済み
            //   (パッチ版 LiveContainer で auth=authorized count=1)。
            //   アラームを登録したのも同じクライアントなので stop() が通る。
            //
            //   止めたあと、抽選も同じ流れで行う。スヌーズのたびに別の曲になる。
            stopForSnooze(payload: payload)

        default:
            HandlerTrace.record("  未対応の action")
            return 1
        }

        guard let data = payload.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let documentsPath = spec["documents"] as? String, !documentsPath.isEmpty,
              let poolPath = spec["pool"] as? String, !poolPath.isEmpty,
              let targetPath = spec["target"] as? String, !targetPath.isEmpty,
              let historyID = spec["historyID"] as? String, !historyID.isEmpty else {
            HandlerTrace.record("  payload を読めません: \(payload)")
            return 1
        }

        let documents = URL(fileURLWithPath: documentsPath, isDirectory: true)
        let pool = URL(fileURLWithPath: poolPath, isDirectory: true)
        let target = URL(fileURLWithPath: targetPath)

        let fm = FileManager.default
        guard fm.fileExists(atPath: target.path) else {
            HandlerTrace.record("  target がありません: \(targetPath)")
            return 2
        }

        // target と同じ拡張子だけを対象にする。ファイル名を変えずに中身だけ
        // 入れ替えるので、拡張子が変わると AlarmKit が読めなくなる。
        let ext = target.pathExtension.lowercased()
        let candidates = SoundShuffle.gatherCandidates(
            in: pool, extensions: ext.isEmpty ? [] : [ext], recursive: true)
        guard !candidates.isEmpty else {
            HandlerTrace.record("  候補が 0 件です pool=\(poolPath) ext=\(ext)")
            return 2
        }

        let store = ShuffleHistoryStore(documents: documents)
        guard let draw = SoundShuffle.pick(candidates: candidates,
                                           historyID: historyID,
                                           store: store) else {
            HandlerTrace.record("  抽選できませんでした")
            return 2
        }

        // 一時ファイル経由で原子的に置き換える。
        // 鳴動中の差し替えでも現在の再生は壊れないことは実測済みだが、
        // 途中で落ちたときに壊れたファイルを残さないようにする。
        let tmp = target.deletingLastPathComponent()
            .appendingPathComponent(".alarm-tmp-\(UUID().uuidString).\(ext)")
        do {
            try? fm.removeItem(at: tmp)
            try fm.copyItem(at: draw.picked, to: tmp)
            _ = try fm.replaceItemAt(target, withItemAt: tmp)
        } catch {
            try? fm.removeItem(at: tmp)
            HandlerTrace.record("  置き換えに失敗: \(error.localizedDescription)")
            return 3
        }

        HandlerTrace.record(
            "  差し替えました \(target.lastPathComponent) <- \(draw.picked.lastPathComponent) "
            + "(候補 \(draw.candidateCount) 曲中、履歴により \(draw.excludedCount) 曲を除外)"
        )
        return 0
    }

    /// `.custom` スヌーズで鳴っているアラートを止め、次の再鳴動を仕込む。
    ///
    /// `AlarmManager.shared.stop(id:)` を呼ばないと鳴り続ける。
    /// 失敗しても抽選だけは続ける (次回の曲は変わる)。
    private static func stopForSnooze(payload: String) {
        guard #available(iOS 26.0, *) else { return }
        guard let data = payload.data(using: .utf8),
              let spec = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let alarmIDString = spec["alarmID"] as? String,
              let alarmID = UUID(uuidString: alarmIDString) else {
            HandlerTrace.record("  スヌーズ: alarmID を読めません")
            return
        }
        let minutes = (spec["snoozeMinutes"] as? Int) ?? 5

        do {
            try AlarmManager.shared.stop(id: alarmID)
            HandlerTrace.record("  スヌーズ: stop() 成功 id=\(alarmIDString.prefix(8))")
        } catch {
            let ns = error as NSError
            HandlerTrace.record(
                "  スヌーズ: stop() 失敗 \(error.localizedDescription) "
                + "[\(ns.domain) code=\(ns.code)]")
            HandlerTrace.record("    → アラートが鳴り続ける可能性があります")
            return
        }

        // 指定分後にもう一度鳴らす。
        //
        // 既存の登録は stop() で止まっただけで、繰り返し設定は生きている。
        // 一時的なカウントダウンを別 ID で仕込む。
        //
        // Intent を渡さない overload を使う。この dylib には
        // AppIntents のメタデータが無いので、Intent 型を持ち込む意味がない。
        //
        // 【既知の制限】この一時アラームはアプリ側の一覧に存在しないため、
        //   スヌーズ待機中にアプリを開くと `syncSchedule` の削除ループに
        //   巻き込まれて消える可能性がある。検証用として許容している。
        let countdown = Alarm.CountdownDuration(
            preAlert: TimeInterval(minutes * 60), postAlert: nil)
        let button = AlarmButton(text: "停止", textColor: .white,
                                 systemImageName: "stop.fill")
        let alert = AlarmPresentation.Alert(title: "アラーム", stopButton: button)
        let attributes = AlarmAttributes<SnoozeMetadata>(
            presentation: AlarmPresentation(alert: alert),
            metadata: SnoozeMetadata(),
            tintColor: .orange)
        let config = AlarmManager.AlarmConfiguration(
            countdownDuration: countdown,
            schedule: nil,
            attributes: attributes,
            sound: .default
        )
        let snoozeID = UUID()
        Task {
            do {
                _ = try await AlarmManager.shared.schedule(
                    id: snoozeID, configuration: config)
                HandlerTrace.record(
                    "  スヌーズ: \(minutes) 分後の再鳴動を登録 id=\(snoozeID.uuidString.prefix(8))")
            } catch {
                HandlerTrace.record("  スヌーズ: 再鳴動の登録に失敗 \(error.localizedDescription)")
            }
        }
    }

    /// AlarmKit がこのプロセスから見えるかを調べる。読み取りのみ。
    private static func probeAlarmKit() {
        guard #available(iOS 26.0, *) else { return }
        let alarms = (try? AlarmManager.shared.alarms) ?? []
        let auth = String(describing: AlarmManager.shared.authorizationState)
        let detail = alarms
            .map { "\($0.id.uuidString.prefix(8)):\($0.state)" }
            .joined(separator: " ")
        HandlerTrace.record("  AlarmKit: auth=\(auth) count=\(alarms.count) [\(detail)]")
        HandlerTrace.record("    count>0 なら stop(id:) も呼べる = スヌーズを .custom にできる")
    }
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
