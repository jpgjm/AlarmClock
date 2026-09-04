//
//  AlarmService.swift
//  AlarmClock
//
//  AlarmKit の薄いラッパ。
//    - 権限リクエスト (`AlarmManager.shared.requestAuthorization()`)
//    - AlarmItem.Schedule → AlarmKit の Alarm.Schedule への変換
//    - AlarmConfiguration の組み立て
//    - スケジュール / 全削除 / 全再登録
//
//  v12 でシンプル化:
//    - 「音楽で起きる」secondary button + OpenAndPlayIntent を廃止
//    - スヌーズは AlarmKit ネイティブ (.countdown behavior) で提供
//  v16 でスヌーズを自前実装に変更:
//    - secondaryButton = スヌーズ、secondaryButtonBehavior = .custom
//    - secondaryIntent = SnoozeAndOpenIntent (押下でアプリを開く)
//    - countdownDuration は使わない (常に nil)
//    - 再鳴動は BackgroundAlarmTasks.createSnoozeInstance() が
//      「N 分後の oneShotAt」を持つスヌーズインスタンスとして登録し直す
//    - snoozeEnabled が false の場合は secondaryButton なし (停止のみ)
//    - stopIntent は StopAndOpenIntent (押下時にアプリを開いて次回抽選) のまま維持
//    - sound: パラメータは customSoundName または フォルダ抽選 or .default
//
//  v28 で LiveContainer 対応を追加:
//    - LiveContainer 内では stopIntent / secondaryIntent を渡さない。
//      ゲストアプリの App Intents は installd に登録されないため、
//      ボタンが押されてもシステムが Intent を解決できない。
//    - スヌーズは .custom ではなく AlarmKit ネイティブの .countdown に切り替える。
//      countdownDuration.postAlert に snoozeMinutes を入れて再鳴動させる。
//    - 判定は RuntimeEnvironment.canUseCustomAppIntents に一元化してある。
//    - この分岐が入るのは登録時の構成だけで、他のロジックは共通。
//

import AlarmKit
import ActivityKit
import AppIntents
import Foundation
import SwiftUI

/// カスタムメタデータを AlarmAttributes に付ける必要がある (AlarmKit の要件)。
/// Countdown Presentation を使わないので基本空でよいが、Codable 実装の型が必要。
struct AlarmClockMetadata: AlarmMetadata {}

/// スケジュール同期の結果。UI で失敗を可視化するために使う。
struct AlarmSyncResult {
    /// 登録に失敗したアラームの ID 集合。
    var failedIDs: Set<UUID> = []
    /// 直近の失敗の内容 (domain / code 付き)。原因究明の手掛かりにする。
    var lastFailureMessage: String?

    var hasFailure: Bool { !failedIDs.isEmpty }
}

/// AlarmKit の薄いラッパ。
///
/// 【v26】`@MainActor` を外した。
///   App Intent (停止 / スヌーズ) を `openAppWhenRun = false` で動かすため、
///   アプリを起動していない文脈からもこのクラスを使う必要がある。
///
///   保持している状態は `manager` (AlarmManager.shared) だけで、
///   これは let かつ AlarmKit 側で管理されるため、複数スレッドから
///   参照しても問題ない。よって `@unchecked Sendable` を付けて共有可能にする。
final class AlarmService: @unchecked Sendable {
    static let shared = AlarmService()

    private let manager = AlarmManager.shared

    /// 【v41 / 検証用トグル】
    ///
    /// LiveContainer 内で、ホスト (パッチ版 LiveContainer) が宣言している
    /// `LCGuestIntent` を stopIntent として渡すかどうか。
    ///
    /// - `true`  : 渡す。停止ボタンでホスト側の perform() が走るかを確かめる
    /// - `false` : 従来どおり stopIntent を渡さない (v40 と同じ挙動)
    ///
    /// 素の LiveContainer で動かす場合や、切り分けのために従来動作へ戻したい場合は
    /// ここを false にする。検証が終わったら、この定数と schedule() 内の分岐を
    /// まとめて削除してよい。
    static let useHostGuestIntent = true

    /// LiveContainer に読み込ませるハンドラの C シンボル名。
    ///
    /// LiveContainer は `RTLD_DEFAULT` から引くので**先勝ち**になる。
    /// 複数のアプリが同じ名前を名乗ると衝突するため、アプリ固有にする。
    /// `Handler/LCGuestHandler.swift` の `@_cdecl` と一致させること。
    static let guestHandlerSymbol = "AlarmClockGuestPerform"

    // MARK: - 権限

    /// 未リクエストなら権限ダイアログを出す。既に決定済みならその状態を返す。
    /// - Returns: 認可されているかどうか
    func ensureAuthorized() async -> Bool {
        switch manager.authorizationState {
        case .authorized:
            return true
        case .denied:
            return false
        case .notDetermined:
            do {
                let state = try await manager.requestAuthorization()
                return state == .authorized
            } catch {
                return false
            }
        @unknown default:
            return false
        }
    }

    // MARK: - スケジュール

    /// アプリ側の AlarmItem 一覧を AlarmKit にまるごと反映する。
    /// 既存の AlarmKit 登録は「アプリで無効化された/削除された分」だけ解除する。
    ///
    /// schedule() 内で毎回 prepared 音源を作り直すため、この呼び出しは
    /// アプリ起動のたびに翌回のアラーム曲を再抽選する役割も担う。
    /// - Returns: 登録に失敗したアラームを含む結果。UI での警告表示に使う。
    @discardableResult
    func syncSchedule(with items: [AlarmItem]) async -> AlarmSyncResult {
        var result = AlarmSyncResult()

        let existing = Set(((try? manager.alarms) ?? []).map { $0.id })
        let desiredEnabled = items.filter { $0.enabled }
        let desiredIds = Set(desiredEnabled.map { $0.id })

        // アプリ側から消えた or 無効化されたものを AlarmKit からも削除する。
        //
        // 【重要】ここは stop ではなく cancel を使う。
        //   stop(id:)   = 鳴っているアラートを止めるだけ。登録は AlarmKit に残り続ける。
        //   cancel(id:) = 登録そのものを削除する。(Apple 公式サンプルの unscheduleAlarm と同じ)
        for id in existing where !desiredIds.contains(id) {
            try? manager.cancel(id: id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
            EventLog.log(.cancel, alarmID: id, message: "アプリ側に無い/無効なため登録解除")
        }

        // 【v22】差分同期に変更した。
        //
        // v21 までは有効な全アラームを毎回 schedule() し直していた。その際
        // schedule() の冒頭で同じ ID を cancel していたが、cancel は AlarmKit 内部で
        // 非同期に処理されるため、直後に同じ ID で schedule すると競合して
        // com.apple.AlarmKit.Alarm error 0 で失敗していた。
        // (診断画面で「登録済 / scheduled」なのにエラーバナーが出る、
        //  purge しても取り残しが消えない、といった症状の原因)
        //
        // そこで「既に AlarmKit に登録されている ID は触らない」ようにする。
        // AlarmKit の登録はアプリを起動しなくても永続するので、これで問題ない。
        //
        // ランダム抽選のやり直しは AlarmAppState 側が担当する。
        // アラームを停止した時などに ID を振り直して登録し直すため、
        // cancel と schedule の ID が別になり競合しない。
        for item in desiredEnabled {
            if existing.contains(item.id) {
                // 既に登録済み → 再登録はしない (競合するため)。
                //
                // 【v30】ただしランダム抽選モードなら、登録は触らずに
                //   prepared ファイルの中身だけを別の曲で上書きする。
                //   AlarmKit に渡してあるファイル名は変わらないので、
                //   登録を作り直す必要がない = 競合も起きない。
                //   これが LiveContainer 内での唯一の再抽選手段になる。
                await refreshSoundIfNeeded(for: item)
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "登録済みのためスキップ (\(String(format: "%02d:%02d", item.hour, item.minute)))")
                continue
            }

            // 【v27】発火時刻が既に過ぎている一回限りアラームは登録しない。
            //
            // AlarmKit は `.fixed(Date)` に過去の日時を渡すと
            // com.apple.AlarmKit.Alarm error 0 で拒否する。
            // 鳴り終わったスヌーズがアプリ側の一覧に残っていると、
            // 編集や新規作成のたびにこの無駄な登録が試みられ、
            // 「アラームを登録できませんでした」の警告が出てしまう。
            if case .oneShotAt(let fireDate) = item.schedule, fireDate < Date() {
                let f = DateFormatter()
                f.locale = Locale(identifier: "ja_JP")
                f.dateFormat = "M/d H:mm"
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "発火時刻 (\(f.string(from: fireDate))) が過去のため登録せず")
                continue
            }

            do {
                try await schedule(item)
                EventLog.log(.scheduleOK, alarmID: item.id,
                             message: "新規登録 \(String(format: "%02d:%02d", item.hour, item.minute)) / \(item.scheduleLabel()) / Intent=\(RuntimeEnvironment.canUseCustomAppIntents ? "あり" : "なし")")
            } catch {
                let ns = error as NSError
                let msg = "\(error.localizedDescription) [domain=\(ns.domain) code=\(ns.code)]"
                debugPrint("AlarmKit schedule failed for \(item.id): \(msg)")
                EventLog.log(.scheduleNG, alarmID: item.id, message: msg)
                result.failedIDs.insert(item.id)
                result.lastFailureMessage = msg
            }
        }

        return result
    }

    /// 登録済みアラームの音源だけを差し替える (v30)。
    ///
    /// AlarmKit の登録には一切触らない。`prepared-{alarmID}.{ext}` という
    /// ファイル名を保ったまま、中身を別の曲で上書きするだけ。
    ///
    /// 対象になるのは次を全て満たすアラームのみ:
    ///   - `soundSourceMode == .random`
    ///   - prepared ファイルが実在する (= 前回フォルダから抽選してコピーされている)
    ///   - 同じ拡張子の候補が 2 つ以上ある
    ///
    /// ユーザーがインポートした音源を直接鳴らしている場合は、実体を壊さないよう
    /// SoundLibraryService 側で弾かれる。
    private func refreshSoundIfNeeded(for item: AlarmItem) async {
        guard item.soundSourceMode == .random else { return }

        guard let refreshed = await SoundLibraryService.shared.refreshPreparedSound(
            alarmID: item.id,
            historyKeyID: item.snoozeSourceID,
            useFolder: item.randomSourceUseFolder,
            folderRelPath: item.folderRelPath,
            libraryFileNames: item.randomSourceLibraryFileNames
        ) else {
            return
        }

        EventLog.log(.reshuffle, alarmID: item.id,
                     message: "登録は維持したまま音源を差し替え: \(refreshed.sourceName) [.\(refreshed.deliveredExtension)] (候補 \(refreshed.candidateCount) 曲中、履歴により \(refreshed.excludedCount) 曲を除外)")
    }

    /// 1件を AlarmKit に登録。既存 ID があれば内部で置き換わる想定 (再登録 = 更新)。
    /// AlarmManager.schedule は `async throws -> Alarm`、
    /// AlarmManager.stop は同期 throws。
    ///
    /// カスタムサウンドの優先順位:
    ///   1. customSoundName が指定されていれば、それを直接再生
    ///   2. なければ folderRelPath (または Documents 直下) から 1 曲ランダム抽選して直接再生
    ///   3. 抽選対象が無ければ .default (システムアラーム音)
    ///
    /// スヌーズ:
    ///   snoozeEnabled が true の場合、secondaryButton にスヌーズを置く。
    ///
    ///   通常インストール時: .custom behavior + SnoozeAndOpenIntent。
    ///     押下すると (アプリは開かずに) BackgroundAlarmTasks.createSnoozeInstance() が
    ///     「N 分後に鳴る一時アラーム (スヌーズインスタンス)」を登録し直す。
    ///     その際に音源の再抽選も走るため、スヌーズのたびに別の曲になる。
    ///
    ///   LiveContainer 内: .countdown behavior (Intent なし)。
    ///     AlarmKit が内部で N 分後に再鳴動させる。アプリは起動しないので
    ///     再抽選は走らず、同じ曲が鳴る。
    func schedule(_ item: AlarmItem) async throws {
        // 【v22】ここで cancel を呼ばない。
        //
        // v18〜v21 では「編集内容を確実に反映させる」ため、schedule の直前に
        // 同じ ID を stop / cancel していた。しかし cancel は AlarmKit 内部で
        // 非同期に処理されるため、直後の schedule と競合して
        // com.apple.AlarmKit.Alarm error 0 を引き起こしていた。
        //
        // 編集時の反映は AlarmAppState が ID を振り直す (replacingID) ことで
        // 担保している。新しい ID には既存登録が無いので、そもそも消す必要がない。
        // 古い ID の登録は syncSchedule の削除ループが片付ける。

        let alarmSchedule = Self.buildAlarmKitSchedule(from: item)

        let stopButton = AlarmButton(
            text: "停止",
            textColor: .white,
            systemImageName: "stop.circle.fill"
        )

        // スヌーズ有効時のみ secondary button を追加。
        //
        // v16 で .countdown から .custom に変更した。
        // .countdown は AlarmKit が内部で再鳴動を処理するためアプリが起動せず、
        //   - スヌーズ再鳴動で同じ曲が鳴り続ける
        //   - 次回アラームの抽選も走らない
        // という制約があった。.custom + SnoozeAndOpenIntent なら押下時にアプリが開き、
        // BackgroundAlarmTasks.createSnoozeInstance() が N 分後の一時アラームを作る。
        //
        // 【v28】LiveContainer 内では .custom が使えないため .countdown に戻す。
        //   ゲストアプリの App Intents は installd に登録されないため、
        //   停止 / スヌーズが押されてもシステムが Intent を解決できない。
        //   .countdown なら AlarmKit の内部処理だけで完結するので動く。
        //   代償として v16 以前の制約 (同じ曲が鳴り続ける / 停止時に再抽選しない) が戻る。
        let useCustomIntents = RuntimeEnvironment.canUseCustomAppIntents

        let alertPresentation: AlarmPresentation.Alert
        let secondaryIntent: SnoozeAndOpenIntent?
        let countdownDuration: Alarm.CountdownDuration?

        if item.snoozeEnabled {
            let snoozeButton = AlarmButton(
                text: "スヌーズ",
                textColor: .white,
                systemImageName: "moon.zzz.fill"
            )
            alertPresentation = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
                stopButton: stopButton,
                secondaryButton: snoozeButton,
                secondaryButtonBehavior: useCustomIntents ? .custom : .countdown
            )
            secondaryIntent = useCustomIntents
                ? SnoozeAndOpenIntent(alarmID: item.id.uuidString)
                : nil
            // .countdown の再鳴動間隔は postAlert で指定する。
            // .custom の時は AlarmKit のカウントダウンを使わないので常に nil。
            countdownDuration = useCustomIntents
                ? nil
                : Alarm.CountdownDuration(
                    preAlert: nil,
                    postAlert: TimeInterval(item.snoozeMinutes * 60)
                  )
        } else {
            alertPresentation = AlarmPresentation.Alert(
                title: LocalizedStringResource(stringLiteral: item.label.isEmpty ? "アラーム" : item.label),
                stopButton: stopButton
            )
            secondaryIntent = nil
            countdownDuration = nil
        }

        // 停止 Intent。
        // 型推論のため、値が nil でも具体的な型 (StopAndOpenIntent?) は保つ。
        let stopIntent: StopAndOpenIntent? = useCustomIntents
            ? StopAndOpenIntent(alarmID: item.id.uuidString)
            : nil

        let presentation = AlarmPresentation(alert: alertPresentation)

        let attributes = AlarmAttributes<AlarmClockMetadata>(
            presentation: presentation,
            tintColor: .orange
        )

        // 音源の決定 (v14 で 3 モード対応)
        //   .defaultSound → .default
        //   .fixed → customSoundName を .named() で直接
        //   .random → prepareAlarmSound() で複数ソースから抽選
        let soundConfig: AlertConfiguration.AlertSound

        // 【v43】LiveContainer 内で LCGuestIntent に渡す payload を組み立てるために、
        //   抽選で置かれた prepared ファイル名を控えておく。
        var preparedFileName: String? = nil

        switch item.soundSourceMode {
        case .defaultSound:
            soundConfig = .default

        case .fixed:
            if let name = item.customSoundName, !name.isEmpty {
                soundConfig = .named(name)
                EventLog.log(.sound, alarmID: item.id, message: "固定音源: \(name)")
            } else {
                soundConfig = .default  // フォールバック (未選択時)
                EventLog.log(.sound, alarmID: item.id, message: "固定音源が未選択のためシステム標準")
            }

        case .random:
            if let prepared = await SoundLibraryService.shared.prepareAlarmSound(
                alarmID: item.id,
                // スヌーズインスタンスは元アラームと抽選履歴を共有する。
                // これにより「元 → スヌーズ 1 → スヌーズ 2」で同じ曲が連続しにくくなる。
                historyKeyID: item.snoozeSourceID,
                useFolder: item.randomSourceUseFolder,
                folderRelPath: item.folderRelPath,
                libraryFileNames: item.randomSourceLibraryFileNames
            ) {
                soundConfig = .named(prepared.alarmKitName)
                preparedFileName = prepared.alarmKitName
                EventLog.log(.sound, alarmID: item.id,
                             message: "抽選: \(prepared.sourceName) [.\(prepared.deliveredExtension)] (候補 \(prepared.candidateCount) 曲中、履歴により \(prepared.excludedCount) 曲を除外)")
            } else {
                soundConfig = .default  // 抽選対象がない時のフォールバック
                EventLog.log(.sound, alarmID: item.id, message: "抽選候補なしのためシステム標準")
            }
        }

        // 【v41 / 検証コード】LiveContainer 内でホスト宣言の Intent を試す。
        //
        //   ゲストが宣言した App Intents は installd に登録されないため解決されない
        //   (v31〜v32 で実測済み)。一方、LiveContainer 自身が宣言した Intent は
        //   登録されている。そこで、パッチ版 LiveContainer が宣言している
        //   `LCGuestIntent` と構造が一致するスタブ (Sources/Intents/LCGuestIntentStub.swift)
        //   を stopIntent に渡し、システムがホスト側の実体を解決するかを確かめる。
        //
        //   AlarmConfiguration は intent の型でジェネリックなので、ここだけ
        //   別に組んで早期 return する。secondaryIntent を stopIntent と同じ型に
        //   揃えているのは、別々の型引数だと nil の型推論が通らないため。
        //
        //   `secondaryButtonBehavior` は useCustomIntents == false のまま
        //   `.countdown` になる。Intent が解決されなくてもアラートは止まる。
        //
        //   検証が終わったらこの分岐と Self.useHostGuestIntent を削除してよい。
        if RuntimeEnvironment.isLiveContainer && Self.useHostGuestIntent {
            // LiveContainer に自分のハンドラを呼んでもらう。
            //
            //   ゲストの**プロセス**を起こす道は 3 通り試して全滅した
            //   (2026-09-04 実測)。前面でないと NSExtension で拡張プロセスを
            //   起こせず、BGContinuedProcessingTask の正式なアサーションが
            //   あっても駄目だった。
            //
            //   そこで LiveContainer のプロセスに読み込まれた自分の dylib を
            //   呼んでもらう形にした。dylib の読み込みは LiveContainer の
            //   既存の Tweaks 機構が担うので、ホスト側に足すのは
            //   「RTLD_DEFAULT からシンボルを引いて呼ぶ」だけで済む。
            //
            //   LiveContainer は action / payload の中身を解釈しない。
            //   抽選も履歴もこちら側の実装。
            let guestPayload = Self.makeGuestPayload(
                for: item, preparedFileName: preparedFileName)

            let hostStopIntent = LCGuestIntent(
                handler: guestPayload == nil ? "" : Self.guestHandlerSymbol,
                action: guestPayload == nil ? "noop" : "reshuffle",
                payload: guestPayload ?? ""
            )

            let lcConfiguration = AlarmManager.AlarmConfiguration<AlarmClockMetadata>(
                countdownDuration: countdownDuration,
                schedule: alarmSchedule,
                attributes: attributes,
                stopIntent: hostStopIntent,
                secondaryIntent: nil as LCGuestIntent?,
                sound: soundConfig
            )

            _ = try await manager.schedule(id: item.id, configuration: lcConfiguration)
            EventLog.log(.scheduleOK, alarmID: item.id,
                         message: "stopIntent = \(Self.guestHandlerSymbol) / payload=\(guestPayload == nil ? "なし" : "あり")")
            return
        }

        let configuration = AlarmManager.AlarmConfiguration<AlarmClockMetadata>(
            // .custom スヌーズでは AlarmKit のカウントダウンを使わないので nil。
            // LiveContainer 内 (.countdown スヌーズ) の時だけ値が入る。
            countdownDuration: countdownDuration,
            schedule: alarmSchedule,
            attributes: attributes,
            // 停止ボタンに Intent を割り当てる。押下時にアプリを開かずに
            // BackgroundAlarmTasks.reshuffleAfterStop() が走り、次回の曲が再抽選される。
            // LiveContainer 内では解決できないので nil。
            stopIntent: stopIntent,
            secondaryIntent: secondaryIntent,
            sound: soundConfig
        )

        _ = try await manager.schedule(id: item.id, configuration: configuration)
    }

    /// LiveContainer に渡す payload を組み立てる (v48)。
    ///
    /// LiveContainer は `handler` のシンボルを `RTLD_DEFAULT` から引いて呼ぶだけで、
    /// `action` と `payload` の中身は解釈しない。抽選も履歴もこちらの都合。
    ///
    /// dylib の読み込みも LiveContainer はしない。既存の Tweaks 機構が担う。
    /// ユーザーが `AlarmHandler.dylib` を「調整をインポート」で置き、
    /// 設定「調整を LiveContainer 自身にも注入」を有効にしておく必要がある。
    ///
    /// パスはすべて **LiveContainer のホームからの相対**。
    /// dylib は LiveContainer のプロセスで走るので、
    /// `NSHomeDirectory()` に結合すれば解決できる。
    ///
    /// nil を返すのは次の場合。呼び出し側は `handler` を空にする。
    ///   - ランダム抽選モードでない
    ///   - prepared ファイルではない (ユーザーがインポートした音源を直接指定して
    ///     いる。実体を壊してはいけないので触らせない)
    ///   - パスが LiveContainer のホーム配下に無い (通常インストール時など)
    private static func makeGuestPayload(
        for item: AlarmItem,
        preparedFileName: String?
    ) -> String? {
        guard item.soundSourceMode == .random else { return nil }
        guard let preparedFileName, preparedFileName.hasPrefix("prepared-") else { return nil }

        let targetURL = RuntimeEnvironment.alarmKitSoundsDirectory
            .appendingPathComponent(preparedFileName)
        guard let target = RuntimeEnvironment.lcRelativePath(for: targetURL) else { return nil }

        guard let documentsURL = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask).first else { return nil }
        guard let documents = RuntimeEnvironment.lcRelativePath(for: documentsURL) else {
            return nil
        }

        // フォルダ抽選でない場合は Documents 直下を対象にする。
        let poolRel = item.randomSourceUseFolder ? (item.folderRelPath ?? "") : ""

        let spec: [String: Any] = [
            "documents": documents,
            "poolRel": poolRel,
            "target": target,
            "historyID": item.id.uuidString,
        ]
        guard let bytes = try? JSONSerialization.data(withJSONObject: spec),
              let text = String(data: bytes, encoding: .utf8) else { return nil }
        return text
    }

    /// 指定アラームの登録を AlarmKit から削除する。
    /// stop ではなく cancel を使うのが正しい (stop は鳴っているアラートを止めるだけ)。
    func cancel(id: UUID) {
        try? manager.cancel(id: id)
        SoundLibraryService.shared.cleanupPreparedSound(alarmID: id)
        EventLog.log(.cancel, alarmID: id, message: "登録解除")
    }

    // MARK: - 診断用

    /// AlarmKit に現在登録されているアラームの ID → state を文字列で返す。
    /// DiagnosticsView が「本当に登録されているか」を可視化するために使う。
    func currentRegisteredAlarmStatesText() -> [UUID: String] {
        let current = (try? manager.alarms) ?? []
        var out: [UUID: String] = [:]
        for a in current {
            out[a.id] = String(describing: a.state)
        }
        return out
    }

    /// 認可状態を文字列で返す (診断表示用)。
    func authorizationStateText() -> String {
        switch manager.authorizationState {
        case .authorized:    return "authorized (許可済み)"
        case .denied:        return "denied (拒否)"
        case .notDetermined: return "notDetermined (未確認)"
        @unknown default:    return "unknown"
        }
    }

    /// アプリ側に存在しない「取り残された登録」を AlarmKit から一掃する。
    ///
    /// v20 まで削除に stop を使っていた影響で、登録が消えずに溜まっている
    /// 環境があるための救済措置。診断画面から手動で実行できるようにしている。
    ///
    /// - Parameter keepingIDs: 残しておく (= アプリ側に存在する) アラーム ID
    /// - Returns: 削除した件数
    @discardableResult
    func purgeOrphanRegistrations(keepingIDs: Set<UUID>) -> Int {
        let current = (try? manager.alarms) ?? []
        var removed = 0
        for a in current where !keepingIDs.contains(a.id) {
            try? manager.cancel(id: a.id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: a.id)
            EventLog.log(.purge, alarmID: a.id, message: "取り残された登録を削除 (state: \(String(describing: a.state)))")
            removed += 1
        }
        debugPrint("[Purge] removed \(removed) orphan registration(s)")
        return removed
    }

    /// AlarmKit に登録されているアラームをすべて削除する。
    func cancelAll() {
        let current = (try? manager.alarms) ?? []
        for a in current {
            try? manager.cancel(id: a.id)
            SoundLibraryService.shared.cleanupPreparedSound(alarmID: a.id)
        }
    }

    // MARK: - 変換

    /// アプリの Schedule 表現 → AlarmKit の Alarm.Schedule。
    ///
    /// - .weekly(days): AlarmKit `.relative` + `.weekly([Locale.Weekday])`
    /// - .oneShotAt(date): AlarmKit `.fixed(Date)`  (UTC 絶対時刻)
    private static func buildAlarmKitSchedule(from item: AlarmItem) -> Alarm.Schedule {
        switch item.schedule {
        case .weekly(let days):
            let time = Alarm.Schedule.Relative.Time(
                hour: item.hour,
                minute: item.minute
            )
            // ISO 曜日 (1=月...7=日) → Locale.Weekday
            let weekdays: [Locale.Weekday] = days.compactMap { d in
                switch d {
                case 1: return .monday
                case 2: return .tuesday
                case 3: return .wednesday
                case 4: return .thursday
                case 5: return .friday
                case 6: return .saturday
                case 7: return .sunday
                default: return nil
                }
            }
            let recurrence: Alarm.Schedule.Relative.Recurrence = weekdays.isEmpty
                ? .never
                : .weekly(weekdays)
            return .relative(
                Alarm.Schedule.Relative(time: time, repeats: recurrence)
            )

        case .oneShotAt(let date):
            // AlarmKit `.fixed(Date)` は UTC 絶対時刻として保存される。
            // TimeZoneWatcher が TZ 変更を検知したら再スケジュールをかける。
            return .fixed(date)
        }
    }
}
