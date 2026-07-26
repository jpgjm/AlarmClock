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
    @State private var showSoundPicker = false
    @State private var showRandomPicker = false
    @State private var showDeleteConfirm = false

    /// 時刻ピッカーのスタイル。アプリ全体の設定として UserDefaults に保存し、
    /// 次にアラームを開いた時も同じスタイルが使われる。デフォルトはホイール。
    @AppStorage("TimePickerStyleOption") private var pickerStyleRaw: String = TimePickerStyleOption.wheel.rawValue

    private var timePickerStyle: TimePickerStyleOption {
        TimePickerStyleOption(rawValue: pickerStyleRaw) ?? .wheel
    }

    /// 時刻ピッカーの表示方式。
    enum TimePickerStyleOption: String, CaseIterable, Identifiable {
        /// iOS 標準のホイール (デフォルト)。
        case wheel
        /// Android Material 風の文字盤ダイヤル (ClockDialPicker)。
        case dial

        var id: String { rawValue }

        var label: String {
            switch self {
            case .wheel: return "ホイール"
            case .dial:  return "文字盤"
            }
        }

        var systemImage: String {
            switch self {
            case .wheel: return "cylinder.split.1x2"
            case .dial:  return "clock"
            }
        }
    }

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
                    Picker("表示方式", selection: $pickerStyleRaw) {
                        ForEach(TimePickerStyleOption.allCases) { style in
                            Label(style.label, systemImage: style.systemImage)
                                .tag(style.rawValue)
                        }
                    }
                    .pickerStyle(.segmented)

                    switch timePickerStyle {
                    case .wheel:
                        DatePicker("時刻", selection: $timeOfDay, displayedComponents: [.hourAndMinute])
                            .datePickerStyle(.wheel)
                            .labelsHidden()
                            .frame(maxWidth: .infinity)
                    case .dial:
                        ClockDialPicker(hour: hourBinding, minute: minuteBinding)
                    }
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
                    Picker("モード", selection: $draft.soundSourceMode) {
                        Text("デフォルト").tag(SoundSourceMode.defaultSound)
                        Text("特定の音源").tag(SoundSourceMode.fixed)
                        Text("ランダム抽選").tag(SoundSourceMode.random)
                    }
                    .pickerStyle(.segmented)

                    switch draft.soundSourceMode {
                    case .defaultSound:
                        Text("iOS 標準のアラーム音を再生します。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .fixed:
                        Button {
                            showSoundPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "bell.badge")
                                Text(fixedSoundDisplayName)
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        Text("インポート済みの音源 1 つを固定的にアラーム音として使います。")
                            .font(.caption)
                            .foregroundStyle(.secondary)

                    case .random:
                        Button {
                            showRandomPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "shuffle")
                                Text(randomSummary)
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                            }
                        }
                        Text("フォルダ内の曲やインポート済みの音源から、指定時刻にランダムで 1 曲抽選して再生します。アプリを開くたびに翌回の曲がシャッフルされます (直近選ばれた曲は連日避けられます)。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("スヌーズ") {
                    Toggle("スヌーズを有効にする", isOn: $draft.snoozeEnabled)
                    if draft.snoozeEnabled {
                        Stepper(value: $draft.snoozeMinutes, in: 1...30) {
                            Text("\(draft.snoozeMinutes) 分後に再鳴動")
                        }
                    }
                    Text("有効にすると AlarmKit のアラート画面に「スヌーズ」ボタンが表示され、押した分後に自動で再鳴動します。再鳴動時のアラーム音は最初と同じものになります (AlarmKit の仕様上、途中で差し替えられないため)。")
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
            .sheet(isPresented: $showSoundPicker) {
                SoundPickerView(selection: $draft.customSoundName)
            }
            .sheet(isPresented: $showRandomPicker) {
                RandomSourcePickerView(
                    useFolder: $draft.randomSourceUseFolder,
                    folderRelPath: $draft.folderRelPath,
                    libraryFileNames: $draft.randomSourceLibraryFileNames
                )
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

    // MARK: - 時刻の Binding
    //
    // timeOfDay (Date) を唯一の真実の源として保ち、ClockDialPicker が要求する
    // Int の hour / minute はそこから導出する。これによりホイールと文字盤を
    // 切り替えても選択中の時刻がずれない。

    private var hourBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.hour, from: timeOfDay) },
            set: { newHour in
                timeOfDay = Self.applying(hour: newHour, minute: nil, to: timeOfDay)
            }
        )
    }

    private var minuteBinding: Binding<Int> {
        Binding(
            get: { Calendar.current.component(.minute, from: timeOfDay) },
            set: { newMinute in
                timeOfDay = Self.applying(hour: nil, minute: newMinute, to: timeOfDay)
            }
        )
    }

    /// 既存の Date の年月日を保ったまま、時 / 分だけを差し替えた Date を返す。
    private static func applying(hour: Int?, minute: Int?, to date: Date) -> Date {
        let cal = Calendar.current
        var comps = cal.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        if let hour { comps.hour = hour }
        if let minute { comps.minute = minute }
        return cal.date(from: comps) ?? date
    }

    /// .fixed モード時にボタンに表示する名前 (customSoundName の displayName、未選択なら「選択してください」)。
    private var fixedSoundDisplayName: String {
        guard let fname = draft.customSoundName, !fname.isEmpty else {
            return "選択してください"
        }
        if let entry = SoundLibraryService.shared.entry(byFileName: fname) {
            return entry.displayName
        }
        return fname
    }

    /// .random モード時にボタンに表示するサマリ。
    private var randomSummary: String {
        var parts: [String] = []
        if draft.randomSourceUseFolder {
            parts.append("フォルダ: \(draft.folderRelPath ?? "全体")")
        }
        let count = draft.randomSourceLibraryFileNames.count
        if count > 0 {
            parts.append("個別 \(count) 曲")
        }
        return parts.isEmpty ? "抽選対象を選択" : parts.joined(separator: " + ")
    }

    /// (旧) アラーム音セクションで表示する現在の選択サウンド名。
    /// v14 では fixedSoundDisplayName / randomSummary に分割したが、
    /// 他から参照されている場合の互換のため残す。
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
