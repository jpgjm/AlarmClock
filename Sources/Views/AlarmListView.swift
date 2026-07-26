//
//  AlarmListView.swift
//  AlarmClock
//
//  アラーム一覧画面。トグルで有効/無効、行タップで編集、右上「+」で新規。
//

import SwiftUI

struct AlarmListView: View {
    @EnvironmentObject private var appState: AlarmAppState

    @State private var editingItem: AlarmItem?
    @State private var isNew: Bool = false

    var body: some View {
        NavigationStack {
            List {
                if appState.alarms.isEmpty {
                    ContentUnavailableView {
                        Label("アラームがまだありません", systemImage: "alarm")
                    } description: {
                        Text("右上の + から新しいアラームを追加できます。\n新規作成時は「毎日 7:00」が初期値です。")
                    }
                    .listRowBackground(Color.clear)
                }
                ForEach(appState.alarms) { alarm in
                    row(for: alarm)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            isNew = false
                            editingItem = alarm
                        }
                }
                .onDelete { indexSet in
                    for i in indexSet {
                        appState.delete(appState.alarms[i].id)
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
