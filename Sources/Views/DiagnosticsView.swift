//
//  DiagnosticsView.swift
//  AlarmClock
//
//  AlarmKit の実際の登録状況を確認するための診断画面。
//
//  「アプリ側では設定できているのに鳴らない」という症状は、
//  AlarmKit 側に本当に登録されているのか / どの状態なのかが見えないと
//  原因を切り分けられない。この画面はその可視化を担う。
//
//  表示するもの:
//    - 実行環境 (通常インストール / LiveContainer のゲスト) と音源の配置先
//    - 権限状態 (authorizationState)
//    - AlarmKit に登録されている全アラーム (ID と state)
//    - アプリ側の AlarmItem との突き合わせ結果
//        * 両方にある      → 正常
//        * アプリのみ      → 登録に失敗している (鳴らない)
//        * AlarmKit のみ   → 取り残された登録 (身に覚えのないアラームが鳴る原因)
//    - 各アラームが使う予定の音源ファイル名と、その実体の有無
//

import AlarmKit
import SwiftUI

struct DiagnosticsView: View {
    @EnvironmentObject private var appState: AlarmAppState
    @Environment(\.dismiss) private var dismiss

    @State private var registered: [UUID: String] = [:]   // AlarmKit 側の ID → state 文字列
    @State private var authState: String = "-"
    @State private var refreshedAt: Date = Date()

    /// ログの件数。一覧そのものは LogView が持つので、ここでは件数だけ保持する。
    @State private var logCount: Int = 0

    /// 起動痕跡。ヘッドレス実行の結果を確認するために使う。
    @State private var traceLast: String? = nil
    @State private var traceCount: Int = 0

    var body: some View {
        NavigationStack {
            List {
                // MARK: 実行環境
                //
                // LiveContainer 内かどうかで動作が変わるため、最初に出す。
                // 「鳴らない」「スヌーズで同じ曲が鳴る」といった症状は、
                // まずここを見れば環境由来かどうかを切り分けられる。
                Section {
                    LabeledContent("種別", value: RuntimeEnvironment.summary)
                    if let hostHome = RuntimeEnvironment.hostHomePath {
                        pathRow(title: "ホストのコンテナ", path: hostHome)
                    }
                } header: {
                    Text("実行環境")
                } footer: {
                    if RuntimeEnvironment.isLiveContainer {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("LiveContainer 内では次の制限があります。")
                            ForEach(RuntimeEnvironment.limitations, id: \.self) { line in
                                Text("・\(line)")
                            }
                        }
                        .font(.caption2)
                        .foregroundStyle(.orange)
                    } else {
                        Text("通常インストールです。すべての機能が利用できます。")
                            .font(.caption2)
                    }
                }

                // MARK: 音源の場所
                //
                // 「どこに曲を置けばいいのか」が分からないという問題は、
                // LiveContainer 内だと特に起きやすい。ファイルアプリでたどれる
                // 表示パスと、実際の絶対パスの両方を出す。
                //
                // 2 つのフォルダは役割が違うので、混同しないよう分けて表示する。
                //   抽選元      … ユーザーが曲を置く場所 (ゲストの Documents)
                //   AlarmKit 用 … 抽選結果をアプリがコピーする場所 (ホストの Library)
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label("抽選元フォルダ", systemImage: "folder")
                            .font(.subheadline.weight(.semibold))
                        Text("ここに曲を入れてください。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        locationDetail(for: RuntimeEnvironment.randomSourceDirectory)
                    }
                    .padding(.vertical, 2)

                    VStack(alignment: .leading, spacing: 6) {
                        Label("AlarmKit が読む場所", systemImage: "speaker.wave.2")
                            .font(.subheadline.weight(.semibold))
                        Text("抽選した曲をアプリが自動でコピーします。手で置く必要はありません。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        locationDetail(for: RuntimeEnvironment.alarmKitSoundsDirectory)
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("音源の場所")
                } footer: {
                    Text("パスは長押しでコピーできます。曲を入れるのは「抽選元フォルダ」だけで、もう一方はアプリが管理します。")
                        .font(.caption2)
                }

                // MARK: 起動痕跡
                //
                // App.init() から記録される。シーンが接続されないヘッドレス起動でも
                // 走るので、「コードがここまで到達したか」をこれで判定できる。
                Section {
                    LabeledContent("記録件数", value: "\(traceCount) 件")
                    if let traceLast {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("最後の記録")
                                .font(.caption)
                            Text(traceLast)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }
                    } else {
                        Text("まだ記録がありません")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    // 【v36】書き込み先が 2 箇所あるので、両方の状態を出す。
                    //   ヘッドレス起動では guest 側にしか書けない。
                    ForEach(LaunchTrace.candidateURLs) { candidate in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(candidate.displayName)
                                    .font(.caption)
                                Spacer()
                                Text(FileManager.default.fileExists(atPath: candidate.url.path)
                                     ? "あり" : "なし")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Text(candidate.url.path)
                                .font(.caption2.monospaced())
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                            if let visible = RuntimeEnvironment.filesAppPath(for: candidate.url) {
                                Text("ファイル: このデバイス内 / \(visible)")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            } else {
                                Text("ファイルアプリからは見えません")
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                    }
                    Button("記録を消す", role: .destructive) {
                        LaunchTrace.clear()
                        reload()
                    }
                    .font(.caption)
                } header: {
                    Text("起動痕跡")
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("記録は 2 段階あります。")
                        Text("・reason=constructor … dlopen された瞬間 (main より前)")
                        Text("・reason=init … App.init()。ここまで来ればアプリとして起動している")
                        Text("行末の「書き込み: guest=OK host=失敗」は、どちらに書けたかを示します。ヘッドレス起動ではホスト側に書けないため、guest だけ OK になるのが正常です。")
                        Text("停止ボタンから LCGuestIntent 経由で音源を差し替えた場合、sounds-writable や「差し替え」の行がここに出ます。")
                    }
                    .font(.caption2)
                }

                Section("権限") {
                    LabeledContent("authorizationState", value: authState)
                }


                Section {
                    LabeledContent("アプリ側のアラーム", value: "\(appState.alarms.count) 件")
                    LabeledContent("AlarmKit の登録", value: "\(registered.count) 件")
                    LabeledContent("最終更新", value: timeText(refreshedAt))
                } header: {
                    Text("概要")
                } footer: {
                    Text("「アプリ側のアラーム」に対して「AlarmKit の登録」が少ない場合、登録に失敗しているアラームがあります。")
                        .font(.caption2)
                }

                Section("突き合わせ") {
                    ForEach(appState.alarms) { alarm in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                                    .font(.headline.monospacedDigit())
                                if !alarm.label.isEmpty {
                                    Text(alarm.label)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                                statusBadge(for: alarm)
                            }
                            Text("id: \(alarm.id.uuidString)")
                                .font(.caption2.monospaced())
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                            if let state = registered[alarm.id] {
                                Text("AlarmKit state: \(state)")
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.secondary)
                            }
                            Text("有効: \(alarm.enabled ? "はい" : "いいえ") / モード: \(modeText(alarm.soundSourceMode))")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                            soundFileStatus(for: alarm)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // AlarmKit にだけ残っている登録 (アプリ側から見えない幽霊アラーム)
                let orphans = registered.keys.filter { id in
                    !appState.alarms.contains(where: { $0.id == id })
                }
                if !orphans.isEmpty {
                    Section {
                        ForEach(orphans, id: \.self) { id in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(id.uuidString)
                                    .font(.caption2.monospaced())
                                    .lineLimit(1)
                                Text("state: \(registered[id] ?? "-")")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        Button(role: .destructive) {
                            purgeOrphans()
                        } label: {
                            Label("取り残された登録をすべて削除", systemImage: "trash")
                        }
                    } header: {
                        Text("取り残された登録 (\(orphans.count) 件)")
                    } footer: {
                        Text("アプリ側に対応するアラームが無いのに AlarmKit に残っているものです。件数が多いとアラーム数の上限に達し、新しいアラームを登録できなくなります。")
                            .font(.caption2)
                    }
                }

                // MARK: ログ
                //
                // 一覧と共有ボタンは専用画面 (LogView) に分離した。
                // 診断画面に詰め込むと縦に長くなりすぎるうえ、iPad では
                // 画面下部の共有ボタンから出るポップオーバーが上方向に展開して
                // 画面全体を覆ってしまうため。
                Section {
                    NavigationLink {
                        LogView()
                    } label: {
                        Label("ログを見る (\(logCount) 件)", systemImage: "list.bullet.rectangle")
                    }
                } header: {
                    Text("ログ")
                } footer: {
                    Text("アラームの作成・登録・停止などの記録を時系列で確認できます。テキストファイルへの書き出しもこの画面から行えます。")
                        .font(.caption2)
                }
            }
            .navigationTitle("診断")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("閉じる") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                }
            }
            .onAppear { reload() }
        }
    }

    // MARK: - Helpers

    /// 「ファイルアプリ上の表示パス」と「実際の絶対パス」を並べて出す。
    /// ファイルアプリからたどれない場所は、その旨を明示する
    /// (探しても見つからず時間を溶かすのを防ぐため)。
    @ViewBuilder
    private func locationDetail(for url: URL) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let visible = RuntimeEnvironment.filesAppPath(for: url) {
                VStack(alignment: .leading, spacing: 1) {
                    Text("「ファイル」アプリ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("このデバイス内 / \(visible)")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            } else {
                VStack(alignment: .leading, spacing: 1) {
                    Text("「ファイル」アプリ")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Text("たどれません (Documents の外にあるため)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 1) {
                Text("実際のパス")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Text(url.path)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
    }

    /// ラベル付きの単一パス表示。
    @ViewBuilder
    private func pathRow(title: String, path: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
            Text(path)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
        }
    }

    private func reload() {
        registered = AlarmService.shared.currentRegisteredAlarmStatesText()
        authState = AlarmService.shared.authorizationStateText()
        logCount = EventLog.count()
        traceLast = LaunchTrace.lastLine()
        traceCount = LaunchTrace.lineCount()
        refreshedAt = Date()
    }

    /// 取り残された登録を一掃して表示を更新する。
    private func purgeOrphans() {
        let keep = Set(appState.alarms.map { $0.id })
        AlarmService.shared.purgeOrphanRegistrations(keepingIDs: keep)
        reload()
    }

    @ViewBuilder
    private func statusBadge(for alarm: AlarmItem) -> some View {
        if !alarm.enabled {
            badge("無効", color: .gray)
        } else if registered[alarm.id] != nil {
            badge("登録済", color: .green)
        } else {
            badge("未登録", color: .red)
        }
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    /// このアラームが使う予定の音源ファイルが実在するかを表示する。
    @ViewBuilder
    private func soundFileStatus(for alarm: AlarmItem) -> some View {
        switch alarm.soundSourceMode {
        case .defaultSound:
            Text("音源: システム標準")
                .font(.caption2)
                .foregroundStyle(.tertiary)

        case .fixed:
            if let name = alarm.customSoundName, !name.isEmpty {
                let exists = SoundLibraryService.shared.soundFileExists(named: name)
                Text("音源: \(name) \(exists ? "✓" : "✗ 見つかりません")")
                    .font(.caption2.monospaced())
                    .foregroundStyle(exists ? Color.secondary : Color.red)
                    .lineLimit(1)
            } else {
                Text("音源: 未選択 (システム標準になります)")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }

        case .random:
            let count = SoundLibraryService.shared.candidateCount(
                useFolder: alarm.randomSourceUseFolder,
                folderRelPath: alarm.folderRelPath,
                libraryFileNames: alarm.randomSourceLibraryFileNames
            )
            Text("抽選候補: \(count) 曲\(count == 0 ? " (システム標準になります)" : "")")
                .font(.caption2)
                .foregroundStyle(count == 0 ? Color.orange : Color.secondary)

            // 【v30】次に鳴る曲を可視化する。
            //   「アプリを開き直すと曲が変わるか」を確かめるには、
            //   実際に鳴らさなくてもここが更新されるかを見れば分かる。
            if let now = SoundLibraryService.shared.currentPreparedSoundDescription(alarmID: alarm.id) {
                Text("次に鳴る曲: \(now)")
                    .font(.caption2)
                    .foregroundStyle(.blue)
                    .lineLimit(2)
            }
        }
    }

    private func modeText(_ mode: SoundSourceMode) -> String {
        switch mode {
        case .defaultSound: return "デフォルト"
        case .fixed:        return "特定の音源"
        case .random:       return "ランダム抽選"
        }
    }

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss"
        return f.string(from: date)
    }
}
