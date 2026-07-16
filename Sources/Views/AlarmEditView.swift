//
//  AlarmEditView.swift
//  AlarmClock
//
//  アラーム 1 件を編集。以下を扱う:
//    - 種別 (曜日繰り返し / 特定日 1 回のみ)
//      * 新規作成時のデフォルトは「曜日繰り返し・毎日 7:00」(明後日単発は特定日1回に切り替えて選択)
//    - 時刻ピッカー
//    - 曜日 Chip 7 個 (種別が weekly の時のみ)
//    - 日付ピッカー (種別が oneShotAt の時のみ)
//    - ラベル
//    - 再生フォルダ (FolderPickerView)
//    - 音量 / フェードイン / スヌーズ設定
//

import SwiftUI

struct AlarmEditView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var appState: AlarmAppState

    let isNew: Bool
    @State private var draft: AlarmItem

    @State private var scheduleKind: ScheduleKind
    @State private var weekdays: Set<Int>
    @State private var oneShotDate: Date
    @State private var timeOfDay: Date
    @State private var showFolderPicker = false
    @State private var showDeleteConfirm = false

    private enum ScheduleKind: String, CaseIterable, Identifiable {
        case weekly = "曜日繰り返し"
        case oneShot = "特定日1回"
        var id: String { rawValue }
    }

    init(item: AlarmItem, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: item)

        // schedule から scheduleKind を復元
        switch item.schedule {
        case .weekly(let days):
            _scheduleKind = State(initialValue: .weekly)
            _weekdays = State(initialValue: days)
            _oneShotDate = State(initialValue: Date())
        case .oneShotAt(let date):
            _scheduleKind = State(initialValue: .oneShot)
            _weekdays = State(initialValue: [])
            _oneShotDate = State(initialValue: date)
        }

        // 時刻ピッカー用 (今日の hour:minute)
        var comps = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        comps.hour = item.hour
        comps.minute = item.minute
        _timeOfDay = State(initialValue: Calendar.current.date(from: comps) ?? Date())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    DatePicker("時刻", selection: $timeOfDay, displayedComponents: [.hourAndMinute])
                        .datePickerStyle(.wheel)
                        .labelsHidden()
                        .frame(maxWidth: .infinity)
                }

                Section("種別") {
                    Picker("種別", selection: $scheduleKind) {
                        ForEach(ScheduleKind.allCases) { k in
                            Text(k.rawValue).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)

                    if scheduleKind == .weekly {
                        weekdayChips
                        HStack {
                            Button("平日") { weekdays = [1, 2, 3, 4, 5] }
                            Button("週末") { weekdays = [6, 7] }
                            Button("毎日") { weekdays = [1, 2, 3, 4, 5, 6, 7] }
                            Button("クリア") { weekdays = [] }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    } else {
                        DatePicker("日付", selection: $oneShotDate, in: Date()..., displayedComponents: [.date])
                        Button("明後日にする") {
                            oneShotDate = Calendar.current.date(byAdding: .day, value: 2, to: Date()) ?? Date()
                        }
                        .font(.footnote)
                    }
                }

                Section("ラベル") {
                    TextField("例: 出張の起床", text: $draft.label)
                }

                Section("再生するフォルダ") {
                    Button {
                        showFolderPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(draft.folderRelPath?.isEmpty == false ? draft.folderRelPath! : "全体 (Documents 直下すべて)")
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    if let p = draft.folderRelPath, !p.isEmpty {
                        Button("全体に戻す") { draft.folderRelPath = nil }
                            .foregroundStyle(.red)
                    }
                    Text("サブフォルダも含めて再帰的にランダム再生します。対応: flac / mp3 / aac / wav / m4a")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("音量") {
                    Slider(value: $draft.volume, in: 0...1) {
                        Text("音量")
                    } minimumValueLabel: {
                        Image(systemName: "speaker.wave.1")
                    } maximumValueLabel: {
                        Image(systemName: "speaker.wave.3")
                    }
                    Text("\(Int(draft.volume * 100))%")
                        .font(.caption)
                }

                Section("フェードイン") {
                    Stepper(value: Binding(
                        get: { Double(draft.fadeInSeconds) },
                        set: { draft.fadeInSeconds = Int($0) }
                    ), in: 0...120, step: 5) {
                        Text(draft.fadeInSeconds == 0 ? "OFF" : "\(draft.fadeInSeconds) 秒")
                    }
                }

                Section("スヌーズ") {
                    Toggle("スヌーズを有効にする", isOn: $draft.snoozeEnabled)
                    if draft.snoozeEnabled {
                        Stepper(value: $draft.snoozeMinutes, in: 1...30) {
                            Text("\(draft.snoozeMinutes) 分間隔")
                        }
                    }
                }

                if !isNew {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirm = true
                        } label: {
                            HStack {
                                Spacer()
                                Label("このアラームを削除", systemImage: "trash")
                                Spacer()
                            }
                        }
                    }
                }
            }
            .navigationTitle(isNew ? "新しいアラーム" : "アラームを編集")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("キャンセル") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") { save() }
                        .disabled(scheduleKind == .weekly && weekdays.isEmpty)
                }
            }
            .sheet(isPresented: $showFolderPicker) {
                NavigationStack {
                    FolderPickerView(initialRelPath: draft.folderRelPath) { rel in
                        draft.folderRelPath = rel
                    }
                }
            }
            .confirmationDialog("このアラームを削除しますか?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
                Button("削除", role: .destructive) {
                    appState.delete(draft.id)
                    dismiss()
                }
                Button("キャンセル", role: .cancel) { }
            }
        }
    }

    @ViewBuilder
    private var weekdayChips: some View {
        let names = ["月", "火", "水", "木", "金", "土", "日"]
        HStack(spacing: 6) {
            ForEach(1...7, id: \.self) { w in
                let selected = weekdays.contains(w)
                Text(names[w - 1])
                    .font(.subheadline.bold())
                    .frame(width: 36, height: 36)
                    .background(selected ? Color.accentColor : Color(.tertiarySystemFill))
                    .foregroundStyle(selected ? .white : .primary)
                    .clipShape(Circle())
                    .onTapGesture {
                        if selected {
                            weekdays.remove(w)
                        } else {
                            weekdays.insert(w)
                        }
                    }
            }
        }
    }

    private func save() {
        let cal = Calendar.current
        let h = cal.component(.hour, from: timeOfDay)
        let m = cal.component(.minute, from: timeOfDay)
        draft.hour = h
        draft.minute = m

        switch scheduleKind {
        case .weekly:
            draft.schedule = .weekly(days: weekdays)
        case .oneShot:
            // 選択された日付 + 時刻を合成
            var comps = cal.dateComponents([.year, .month, .day], from: oneShotDate)
            comps.hour = h
            comps.minute = m
            let combined = cal.date(from: comps) ?? oneShotDate
            draft.schedule = .oneShotAt(date: combined)
        }
        draft.enabled = true

        appState.addOrUpdate(draft)
        dismiss()
    }
}
