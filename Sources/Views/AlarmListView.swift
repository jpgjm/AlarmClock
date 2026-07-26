//
//  AlarmListView.swift
//  AlarmClock
//
//  アラーム一覧画面。トグルで有効/無効、行タップで編集、右上「+」で新規。
//
//  v16 追加:
//    - スヌーズインスタンス (isSnoozeInstance) は一覧から除外し、
//      代わりに「スヌーズ中」バナーとして上部にまとめて表示する
//    - スヌーズ受付時のメッセージを一時バナーで通知する
//

import SwiftUI

struct AlarmListView: View {
    @EnvironmentObject private var appState: AlarmAppState

    @State private var editingItem: AlarmItem?
    @State private var isNew: Bool = false
    @State private var showDiagnostics: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // AlarmKit への登録に失敗した場合の警告。
                // 通常は出ないが、出た場合は時刻を変えても鳴らない状態になっている。
                if !appState.failedAlarmIDs.isEmpty {
                    Section {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Label("アラームを登録できませんでした", systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline.weight(.semibold))
                                    .foregroundStyle(.red)
                                Spacer()
                                Button {
                                    appState.dismissScheduleFailure()
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                            }
                            Text("該当のアラームは指定時刻に鳴りません。アラームを開いて保存し直すか、いったん削除して作り直してください。")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if let msg = appState.lastScheduleFailureMessage, !msg.isEmpty {
                                Text(msg)
                                    .font(.caption2.monospaced())
                                    .foregroundStyle(.red.opacity(0.9))
                                    .textSelection(.enabled)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                // スヌーズ受付直後の通知
                if let notice = appState.snoozeNotice {
                    Section {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "moon.zzz.fill")
                                .foregroundStyle(.orange)
                            Text(notice)
                                .font(.footnote)
                            Spacer()
                            Button {
                                appState.dismissSnoozeNotice()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 発火待ちのスヌーズ
                if !appState.pendingSnoozeInstances.isEmpty {
                    Section("スヌーズ中") {
                        ForEach(appState.pendingSnoozeInstances) { snooze in
                            HStack {
                                Image(systemName: "moon.zzz.fill")
                                    .foregroundStyle(.orange)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(String(format: "%02d:%02d", snooze.hour, snooze.minute))
                                        .font(.title3.monospacedDigit())
                                    if !snooze.label.isEmpty {
                                        Text(snooze.label)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(1)
                                    }
                                }
                                Spacer()
                                Button("取り消す") {
                                    appState.cancelSnooze(forRootID: snooze.snoozeSourceID ?? snooze.id)
                                }
                                .buttonStyle(.borderless)
                                .font(.footnote)
                            }
                        }
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
                ToolbarItem(placement: .topBarLeading) {
                    Button {
                        showDiagnostics = true
                    } label: {
                        Image(systemName: "stethoscope")
                    }
                    .accessibilityLabel("診断")
                }
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
            .sheet(isPresented: $showDiagnostics) {
                DiagnosticsView()
                    .environmentObject(appState)
            }
        }
    }

    @ViewBuilder
    private func row(for alarm: AlarmItem) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(String(format: "%02d:%02d", alarm.hour, alarm.minute))
                        .font(.system(size: 34, weight: .light, design: .rounded))
                        .foregroundStyle(alarm.enabled ? .primary : .secondary)
                    if appState.failedAlarmIDs.contains(alarm.id) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                            .accessibilityLabel("登録に失敗しました")
                    }
                }
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
