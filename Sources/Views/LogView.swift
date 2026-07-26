//
//  LogView.swift
//  AlarmClock
//
//  診断ログの専用画面。
//
//  なぜ独立した画面にしたか:
//    診断画面の中にログを詰め込むと、縦に長くなりすぎてスクロールが大変だった。
//    独立させることで一覧を広く使え、絞り込みなどの操作も置きやすくなる。
//
//  共有について:
//    SwiftUI の ShareLink は iPad でポップオーバー表示になり、
//    呼び出し元ボタンの位置によっては画面外にはみ出して見切れる。
//    そこで UIActivityViewController を `.sheet` で包む ShareSheet を使い、
//    画面中央にモーダル表示されるようにしている。
//

import SwiftUI

struct LogView: View {
    @State private var logs: [LogEntry] = []
    /// 共有シートに渡す対象。nil でない間シートが開く。
    @State private var shareTarget: ShareTarget?
    /// 書き出しに失敗した時のメッセージ。
    @State private var exportError: String?
    @State private var showClearConfirm = false

    /// 絞り込み中のカテゴリ。nil ならすべて表示。
    @State private var filter: String?

    /// 絞り込み後のログ。
    private var visibleLogs: [LogEntry] {
        guard let filter else { return logs }
        return logs.filter { $0.category == filter }
    }

    /// 実際に記録されているカテゴリだけを絞り込み候補にする。
    private var availableCategories: [String] {
        var seen = Set<String>()
        var ordered: [String] = []
        for entry in logs where !seen.contains(entry.category) {
            seen.insert(entry.category)
            ordered.append(entry.category)
        }
        return ordered.sorted()
    }

    var body: some View {
        List {
            if logs.isEmpty {
                ContentUnavailableView {
                    Label("記録がありません", systemImage: "list.bullet.rectangle")
                } description: {
                    Text("アラームの作成・停止などを行うとここに記録されます。")
                }
                .listRowBackground(Color.clear)
            } else {
                if !availableCategories.isEmpty {
                    Section {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: 8) {
                                filterChip(title: "すべて", value: nil)
                                ForEach(availableCategories, id: \.self) { category in
                                    filterChip(title: category, value: category)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    } header: {
                        Text("絞り込み")
                    }
                }

                Section {
                    ForEach(visibleLogs) { entry in
                        row(for: entry)
                    }
                } header: {
                    Text(filter == nil
                         ? "\(visibleLogs.count) 件 (新しい順)"
                         : "\(filter!): \(visibleLogs.count) 件")
                } footer: {
                    Text("右上の ⬆️ を押すとテキストファイルに書き出して共有メニューを開きます。書き出したファイルは「ファイル」アプリの Alarm Clock → Log フォルダにも残ります。")
                        .font(.caption2)
                }
            }
        }
        .navigationTitle("ログ")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            // 共有ボタン。押すとその場でファイルを書き出し、
            // 共有シートを sheet として開く。
            // (ShareLink のポップオーバーだと iPad で見切れるため)
            ToolbarItem(placement: .primaryAction) {
                Button {
                    exportAndShare()
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(logs.isEmpty)
            }

            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        reload()
                    } label: {
                        Label("更新", systemImage: "arrow.clockwise")
                    }
                    Button(role: .destructive) {
                        showClearConfirm = true
                    } label: {
                        Label("ログを消去", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
        }
        .onAppear { reload() }
        .sheet(item: $shareTarget) { target in
            ShareSheet(items: [target.url])
        }
        .confirmationDialog("ログをすべて消去しますか?", isPresented: $showClearConfirm, titleVisibility: .visible) {
            Button("消去", role: .destructive) {
                EventLog.clear()
                reload()
            }
            Button("キャンセル", role: .cancel) { }
        }
        .alert("書き出しに失敗しました",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } }),
               presenting: exportError) { _ in
            Button("OK", role: .cancel) { exportError = nil }
        } message: { msg in
            Text(msg)
        }
    }

    // MARK: - Parts

    @ViewBuilder
    private func filterChip(title: String, value: String?) -> some View {
        let isSelected = (filter == value)
        Button {
            filter = value
        } label: {
            Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(isSelected ? Color.accentColor : Color(.tertiarySystemFill))
                .foregroundStyle(isSelected ? Color.white : Color.primary)
                .clipShape(Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func row(for entry: LogEntry) -> some View {
        VStack(alignment: .leading, spacing: 3) {
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
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            if let id = entry.alarmID, !id.isEmpty {
                Text("id: \(id)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(Color.secondary)
                    .lineLimit(1)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 3)
    }

    // MARK: - Helpers

    private func reload() {
        logs = EventLog.entries()
    }

    /// ログをファイルに書き出し、そのまま共有シートを開く。
    private func exportAndShare() {
        if let url = EventLog.writeExportFile() {
            shareTarget = ShareTarget(url: url)
        } else {
            exportError = "ログファイルを作成できませんでした。空き容量を確認してください。"
        }
    }

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

    private func timeText(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "ja_JP")
        f.dateFormat = "H:mm:ss.SSS"
        return f.string(from: date)
    }
}
