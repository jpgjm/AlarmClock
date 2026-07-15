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
                        Text("右上の + から新しいアラームを追加できます。\n新規作成時は「明後日 7:00」が初期値です。")
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
                        editingItem = AlarmItem.defaultDayAfterTomorrow()
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
                if let f = alarm.folderRelPath, !f.isEmpty {
                    Label(f, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
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
}
