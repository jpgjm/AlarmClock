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

    /// 画面に表示するログ (新しい順)。
    @State private var logs: [LogEntry] = []
    /// 書き出したログファイルの URL。ShareLink に渡す。
    @State private var exportURL: URL?
    @State private var showClearConfirm = false

    var body: some View {
        NavigationStack {
            List {
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
                Section {
                    if let url = exportURL {
                        ShareLink(item: url) {
                            Label("ログを書き出して共有", systemImage: "square.and.arrow.up")
                        }
                    } else {
                        Button {
                            prepareExport()
                        } label: {
                            Label("ログを書き出す", systemImage: "square.and.arrow.up")
                        }
                    }

                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("ログを消去", systemImage: "trash")
                    }
                } header: {
                    Text("ログ (\(logs.count) 件)")
                } footer: {
                    Text("「書き出す」を押すとテキストファイルを作成します。続けて表示される共有メニューから「ファイルに保存」を選ぶと取り出せます。書き出したファイルは「ファイル」アプリの Alarm Clock フォルダにも残ります。")
                        .font(.caption2)
                }

                Section("最近の出来事") {
                    if logs.isEmpty {
                        Text("まだ記録がありません。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(logs.prefix(80)) { entry in
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(entry.category)
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(categoryColor(entry.category))
                                    Spacer()
                                    Text(timeText(entry.timestamp))
                                        .font(.caption2.monospacedDigit())
                                        .foregroundStyle(Color.secondary)
                                }
                                if !entry.message.isEmpty {
                                    Text(entry.message)
                                        .font(.caption2)
                                        .fixedSize(horizontal: false, vertical: true)
                                }
                                if let id = entry.alarmID, !id.isEmpty {
                                    Text("id: \(id)")
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(Color.secondary)
                                        .lineLimit(1)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
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
            .confirmationDialog("ログをすべて消去しますか?", isPresented: $showClearConfirm, titleVisibility: .visible) {
                Button("消去", role: .destructive) {
                    EventLog.clear()
                    reload()
                }
                Button("キャンセル", role: .cancel) { }
            }
        }
    }

    // MARK: - Helpers

    private func reload() {
        registered = AlarmService.shared.currentRegisteredAlarmStatesText()
        authState = AlarmService.shared.authorizationStateText()
        logs = EventLog.entries()
        refreshedAt = Date()
        // 内容が変わったので、以前書き出したファイルの共有ボタンは一旦引っ込める
        exportURL = nil
    }

    /// ログをテキストファイルに書き出し、共有ボタンを出せる状態にする。
    private func prepareExport() {
        exportURL = EventLog.writeExportFile()
    }

    /// カテゴリごとの色分け。異常系は赤系にして目を引くようにする。
    private func categoryColor(_ category: String) -> Color {
        switch category {
        case EventLog.Category.scheduleNG.rawValue:  return .red
        case EventLog.Category.scheduleOK.rawValue:  return .green
        case EventLog.Category.stopPressed.rawValue: return .orange
        case EventLog.Category.snoozePress.rawValue: return .orange
        case EventLog.Category.reshuffle.rawValue:   return .blue
        case EventLog.Category.purge.rawValue:       return .purple
        default:                                     return .primary
        }
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
