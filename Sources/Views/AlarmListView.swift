//
//  AlarmListView.swift
//  AlarmClock
//
//  アラーム一覧画面。トグルで有効/無効、行タップで編集、右上「+」で新規。
//
//  v17 (案 B の検証):
//    - スヌーズは AlarmKit ネイティブ (.countdown) に戻したため
//      「スヌーズ中」セクションは廃止 (アプリ側では進行状況を把握できない)
//    - 代わりに「secondaryIntent が呼ばれたか」の検証バナーを表示する
//

import SwiftUI

struct AlarmListView: View {
    @EnvironmentObject private var appState: AlarmAppState

    @State private var editingItem: AlarmItem?
    @State private var isNew: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // 案 B の検証結果バナー。
                // これが出れば `.countdown` でも secondaryIntent が呼ばれると確認できる。
                if let report = appState.snoozeIntentReport {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            Text(report)
                                .font(.footnote)
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 0)
                            Button {
                                appState.dismissSnoozeIntentReport()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    } footer: {
                        Text("スヌーズを押した後にこのバナーが出た場合、.countdown でも secondaryIntent が呼ばれています。閉じると次回の同期でアラームが再登録されます。")
                            .font(.caption2)
                    }
                }

                if appState.visibleAlarms.isEmpty {
                    ContentUnavailableView {
                        Label("アラームがまだありません", systemImage: "alarm")
                    } description: {
                        Text("右上の + から新しいアラームを追加できます。\n新規作成時は「毎日・現在時刻」が初期値です。")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(appState.visibleAlarms) { alarm in
                    row(for: alarm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isNew = false
                            editingItem = alarm
                        }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        appState.delete(appState.visibleAlarms[i].id)
                    }
                }
            }
            .navigationTitle("目覚まし")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        isNew = true
                        editingItem = AlarmItem.defaultForNewAlarm()
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editingItem) { item in
                AlarmEditView(item: item, isNew: isNew)
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func row(for alarm: AlarmItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                    .font(.system(size: 34, weight: .light, design: .rounded))
                    .foregroundStyle(alarm.enabled ? .primary : .secondary)
                if !alarm.label.isEmpty {
                    Text(alarm.label)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Text(alarm.scheduleLabel())
                    .font(.caption)
                    .foregroundStyle(.tertiary)

                // 音源の要約 (モード別)
                soundSummaryLabel(for: alarm)
            }
            Spacer()
            Toggle("", isOn: Binding(
                get: { alarm.enabled },
                set: { appState.toggleEnabled(alarm.id, enabled: $0) }
            ))
            .labelsHidden()
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func soundSummaryLabel(for alarm: AlarmItem) -> some View {
        switch alarm.soundSourceMode {
        case .defaultSound:
            EmptyView()

        case .fixed:
            if let sn = alarm.customSoundName, !sn.isEmpty {
                let name = SoundLibraryService.shared.entry(byFileName: sn)?.displayName ?? sn
                Label(name, systemImage: "bell.badge")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }

        case .random:
            var parts: [String] = []
            let _ = {
                if alarm.randomSourceUseFolder {
                    parts.append(alarm.folderRelPath ?? "全体")
                }
                let count = alarm.randomSourceLibraryFileNames.count
                if count > 0 {
                    parts.append("個別 \(count)曲")
                }
            }()
            if !parts.isEmpty {
                Label(parts.joined(separator: " + "), systemImage: "shuffle")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }
}
