//
//  AlarmListView.swift
//  AlarmClock
//
//  アラーム一覧画面。トグルで有効/無効、行タップで編集、右上「+」で新規。
//
//  改良点:
//    - AlarmKit 認可拒否 / スケジュール失敗を警告バナーで表示
//    - 一過性警告 (transientWarning) を alert で表示
//    - スケジュール失敗した行に赤い警告アイコン
//

import SwiftUI
import UIKit

struct AlarmListView: View {
    @EnvironmentObject private var appState: AlarmAppState

    @State private var editingItem: AlarmItem?
    @State private var isNew: Bool = false

    var body: some View {
        NavigationStack {
            List {
                // MARK: 警告バナー (認可拒否)
                if appState.authorizationDenied {
                    Section {
                        authorizationDeniedBanner
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

                // MARK: 警告バナー (スケジュール失敗)
                if !appState.failedAlarmIDs.isEmpty {
                    Section {
                        scheduleFailureBanner
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                }

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
            .alert(
                "音源が見つかりません",
                isPresented: Binding(
                    get: { appState.transientWarning != nil },
                    set: { if !$0 { appState.dismissTransientWarning() } }
                ),
                presenting: appState.transientWarning
            ) { _ in
                Button("OK", role: .cancel) { appState.dismissTransientWarning() }
            } message: { msg in
                Text(msg)
            }
        }
    }

    // MARK: - Banners

    private var authorizationDeniedBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("アラーム権限が拒否されています", systemImage: "exclamationmark.triangle.fill")
                .font(.headline)
                .foregroundStyle(.orange)
            Text("このままではアラームは鳴りません。設定 → Alarm Clock で「アラームとタイマー」を許可してください。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Button("設定を開く") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
            .font(.footnote.weight(.semibold))
            .padding(.top, 2)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12))
        .cornerRadius(10)
    }

    private var scheduleFailureBanner: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("一部のアラームをシステムに登録できませんでした", systemImage: "xmark.octagon.fill")
                .font(.headline)
                .foregroundStyle(.red)
            Text("v7 は Apple 公式サンプル SchedulingAnAlarmWithAlarmKit と同等の最小構成 (Widget Extension なし、Info.plist は NSAlarmKitUsageDescription のみ) です。これでも失敗する場合、SideStore の自己署名で AlarmKit そのものが動かない可能性が高く、ローカル通知への切り替えを検討する必要があります。")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let msg = appState.lastScheduleFailureMessage, !msg.isEmpty {
                Divider().padding(.vertical, 2)
                Text("AlarmKit エラー: \(msg)")
                    .font(.caption.monospaced())
                    .foregroundStyle(.red.opacity(0.9))
                    .textSelection(.enabled)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.red.opacity(0.12))
        .cornerRadius(10)
    }

    // MARK: - Row

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
                            .accessibilityLabel("スケジュールに失敗しました")
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
                if let f = alarm.folderRelPath, !f.isEmpty {
                    Label(f, systemImage: "folder")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
                if !alarm.musicLibraryItemIDs.isEmpty {
                    Label("Apple Music \(alarm.musicLibraryItemIDs.count)曲",
                          systemImage: "music.note")
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
