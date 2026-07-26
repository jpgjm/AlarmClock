//
//  AlarmEditView.swift
//  AlarmClock
//
//  アラーム 1 件を編集。以下を扱う:
//    - 種別 (曜日繰り返し / 特定日 1 回のみ)
//    - 時刻ピッカー
//    - 曜日 Chip 7 個 (種別が weekly の時のみ)
//    - 日付ピッカー (種別が oneShotAt の時のみ)
//    - ラベル
//    - アラーム音 (SoundPickerView)
//    - 再生フォルダ (FolderPickerView)
//    - スヌーズ設定
//
//  v12 でシンプル化:
//    - Apple Music の曲、音量、フェードイン セクションを削除
//    - スヌーズは AlarmKit ネイティブに任せる (secondary button として表示)
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
    @State private var showSoundPicker = false
    @State private var showDeleteConfirm = false

    private enum ScheduleKind: String, CaseIterable, Identifiable {
        case weekly = "曜日繰り返し"
        case oneShot = "特定日1回"
        var id: String { rawValue }
    }

    init(item: AlarmItem, isNew: Bool) {
        self.isNew = isNew
        _draft = State(initialValue: item)

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

                Section("アラーム音") {
                    Button {
                        showSoundPicker = true
                    } label: {
                        HStack {
                            Image(systemName: "bell.badge")
                            Text(soundDisplayName)
                                .lineLimit(1)
                            Spacer()
                            Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                        }
                    }
                    Text("AlarmKit の Alert がここで指定したサウンドを直接再生します。ファイルは Library/Sounds に保存されます。iOS 26.0 では MP3/M4A が壊れているバグ報告あり (26.1+ で改善)。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
                    Text("「アラーム音」を「デフォルト」にしている時、指定時刻にフォルダから1曲ランダムで直接鳴ります (アプリを開くたびに翌回の曲がシャッフルされます)。対応: wav / aiff / caf (推奨) / mp3 / m4a / aac。flac は AlarmKit 非対応で除外されます。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("スヌーズ") {
                    Toggle("スヌーズを有効にする", isOn: $draft.snoozeEnabled)
                    if draft.snoozeEnabled {
                        Stepper(value: $draft.snoozeMinutes, in: 1...30) {
                            Text("\(draft.snoozeMinutes) 分後に再鳴動")
                        }
                    }
                    Text("有効にすると AlarmKit のアラート画面に「スヌーズ」ボタンが表示されます。押した分後に自動で再鳴動します。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
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
            .sheet(isPresented: $showSoundPicker) {
                SoundPickerView(selection: $draft.customSoundName)
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

    /// アラーム音セクションで表示する現在の選択サウンド名。
    private var soundDisplayName: String {
        guard let fname = draft.customSoundName, !fname.isEmpty else {
            return "デフォルト"
        }
        if let entry = SoundLibraryService.shared.entry(byFileName: fname) {
            return entry.displayName
        }
        return fname
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
