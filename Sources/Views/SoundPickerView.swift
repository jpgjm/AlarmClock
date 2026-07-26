//
//  SoundPickerView.swift
//  AlarmClock
//
//  カスタムアラーム音の選択画面。DayAfterTomorrow のサウンド選択 UI と同等の構成。
//    - デフォルト (システムアラーム音)
//    - インポート済み一覧 (SoundLibraryService から)
//    - 音声ファイルを追加... (Files アプリからのピッカー)
//
//  選択結果は `selection: Binding<String?>` に反映する
//  (nil = デフォルト、値 = "UUID.wav" 形式のファイル名)。
//

import SwiftUI
import UniformTypeIdentifiers
import AVFoundation
import MediaPlayer

struct SoundPickerView: View {
    /// 選択中のカスタム音源ファイル名。nil = デフォルト。AlarmItem.customSoundName にバインド。
    @Binding var selection: String?

    @Environment(\.dismiss) private var dismiss

    @State private var entries: [SoundEntry] = []
    @State private var showingImporter: Bool = false
    @State private var showingMusicPicker: Bool = false
    @State private var isImportingFromMusic: Bool = false
    @State private var importErrorMessage: String?
    @State private var previewPlayer: AVAudioPlayer?

    private let library = SoundLibraryService.shared

    var body: some View {
        NavigationStack {
            List {
                Section {
                    // デフォルト行 (システムアラーム音)
                    rowView(
                        title: "デフォルト",
                        subtitle: nil,
                        isSelected: selection == nil,
                        canPreview: false,
                        onSelect: { selection = nil },
                        onPreview: nil
                    )

                    // インポート済み
                    ForEach(entries) { entry in
                        rowView(
                            title: entry.displayName,
                            subtitle: entry.fileName,
                            isSelected: selection == entry.fileName,
                            canPreview: true,
                            onSelect: { selection = entry.fileName },
                            onPreview: { previewSound(entry: entry) }
                        )
                    }
                    .onDelete(perform: deleteEntries)
                } header: {
                    Text("サウンド選択")
                }

                Section {
                    Button {
                        showingImporter = true
                    } label: {
                        Label("音声ファイルを追加...", systemImage: "plus.circle")
                    }

                    Button {
                        Task { await presentMusicPicker() }
                    } label: {
                        HStack {
                            Label("音楽ライブラリから追加...", systemImage: "music.note.list")
                            Spacer()
                            if isImportingFromMusic {
                                ProgressView()
                            }
                        }
                    }
                    .disabled(isImportingFromMusic)
                } footer: {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("ファイル追加: WAV, AIFF, CAF (推奨) / MP3, M4A")
                        Text("音楽ライブラリ: 「ミュージック」アプリの曲を m4a に書き出して追加します。**Apple Music のサブスクリプション曲は DRM 保護のため使用不可**。iTunes 同期や DRM 無しの購入曲を選んでください。")
                        Text("MP3 / M4A は iOS 26.0 では鳴らない既知バグあり (26.1+ で改善)")
                            .foregroundStyle(.tertiary)
                    }
                    .font(.caption2)
                }
            }
            .navigationTitle("サウンド選択")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        stopPreview()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .onAppear { reload() }
            .onDisappear { stopPreview() }
            .fileImporter(
                isPresented: $showingImporter,
                allowedContentTypes: [.audio, .wav, .aiff, UTType(filenameExtension: "caf") ?? .audio, .mp3, .mpeg4Audio],
                allowsMultipleSelection: false
            ) { result in
                handleImport(result: result)
            }
            .sheet(isPresented: $showingMusicPicker) {
                MusicPickerBridge { mediaItem in
                    handleMusicPick(mediaItem: mediaItem)
                }
                .ignoresSafeArea()
            }
            .alert("追加に失敗しました",
                   isPresented: Binding(get: { importErrorMessage != nil },
                                        set: { if !$0 { importErrorMessage = nil } }),
                   presenting: importErrorMessage) { _ in
                Button("OK", role: .cancel) { importErrorMessage = nil }
            } message: { msg in
                Text(msg)
            }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func rowView(
        title: String,
        subtitle: String?,
        isSelected: Bool,
        canPreview: Bool,
        onSelect: @escaping () -> Void,
        onPreview: (() -> Void)?
    ) -> some View {
        HStack {
            Button {
                onSelect()
            } label: {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(isSelected ? Color.accentColor : Color.primary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption2.monospaced())
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if isSelected {
                Image(systemName: "checkmark")
                    .foregroundStyle(Color.accentColor)
            }
            if canPreview, let onPreview {
                Button {
                    onPreview()
                } label: {
                    Image(systemName: "play.circle")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Actions

    private func reload() {
        entries = library.entries()
    }

    private func deleteEntries(at offsets: IndexSet) {
        for i in offsets {
            let entry = entries[i]
            // 選択中のものを消す場合は選択解除
            if selection == entry.fileName {
                selection = nil
            }
            library.delete(entry)
        }
        reload()
    }

    private func handleImport(result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let sourceURL = urls.first else { return }
            let didStart = sourceURL.startAccessingSecurityScopedResource()
            defer { if didStart { sourceURL.stopAccessingSecurityScopedResource() } }
            if let entry = library.importSound(from: sourceURL) {
                reload()
                selection = entry.fileName
            } else {
                importErrorMessage = "このファイル形式には対応していません (WAV / AIFF / CAF / MP3 / M4A のみ)。"
            }
        case .failure(let error):
            importErrorMessage = error.localizedDescription
        }
    }

    // MARK: - Music Library Import

    /// 音楽ライブラリピッカーを開く前に権限を確認。
    /// 未決定なら requestAuthorization、拒否済みなら案内メッセージ。
    @MainActor
    private func presentMusicPicker() async {
        let status = MPMediaLibrary.authorizationStatus()
        switch status {
        case .authorized:
            showingMusicPicker = true
        case .notDetermined:
            let newStatus = await withCheckedContinuation { (cont: CheckedContinuation<MPMediaLibraryAuthorizationStatus, Never>) in
                MPMediaLibrary.requestAuthorization { s in cont.resume(returning: s) }
            }
            if newStatus == .authorized {
                showingMusicPicker = true
            } else {
                importErrorMessage = "音楽ライブラリへのアクセスが許可されませんでした。設定 → Alarm Clock → メディアとApple Musicで許可してください。"
            }
        case .denied, .restricted:
            importErrorMessage = "音楽ライブラリへのアクセスが拒否されています。設定 → Alarm Clock → メディアとApple Musicで許可してください。"
        @unknown default:
            importErrorMessage = "音楽ライブラリの権限状態が不明です。"
        }
    }

    /// MusicPickerBridge から曲が選ばれた時に呼ばれる。
    /// AVAssetExportSession で Library/Sounds/{UUID}.m4a に書き出す。
    private func handleMusicPick(mediaItem: MPMediaItem) {
        isImportingFromMusic = true
        Task {
            defer {
                Task { @MainActor in isImportingFromMusic = false }
            }
            do {
                let entry = try await library.importFromMediaItem(mediaItem)
                await MainActor.run {
                    reload()
                    selection = entry.fileName
                }
            } catch {
                await MainActor.run {
                    importErrorMessage = error.localizedDescription
                }
            }
        }
    }

    // MARK: - Preview playback

    private func previewSound(entry: SoundEntry) {
        stopPreview()
        let libraryURL = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let url = libraryURL.appendingPathComponent("Sounds").appendingPathComponent(entry.fileName)
        do {
            try AVAudioSession.sharedInstance().setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(contentsOf: url)
            p.prepareToPlay()
            p.play()
            previewPlayer = p
        } catch {
            debugPrint("[SoundPicker] preview failed: \(error)")
        }
    }

    private func stopPreview() {
        previewPlayer?.stop()
        previewPlayer = nil
    }
}
