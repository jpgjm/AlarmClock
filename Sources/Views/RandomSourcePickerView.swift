//
//  RandomSourcePickerView.swift
//  AlarmClock
//
//  「アラーム音」を「ランダム抽選」モードにした時の、抽選対象を選ぶ画面。
//    - フォルダ (Documents/{folderRelPath}) を抽選対象にする / しない のトグル
//    - フォルダを選ぶボタン (FolderPickerView)
//    - Library/Sounds の SoundEntry ごとにチェックボックス
//    - 全て選択 / 全て解除
//    - 選択済みの件数を header に表示 (例: "個別の音源 (3 / 10 選択)")
//
//  データバインディング:
//    - useFolder: Bool         (フォルダを抽選対象に含めるか)
//    - folderRelPath: String?  (Documents ルートからの相対パス)
//    - libraryFileNames: Set<String>  (Library/Sounds/xxx.ext のファイル名集合)
//

import SwiftUI

struct RandomSourcePickerView: View {
    @Binding var useFolder: Bool
    @Binding var folderRelPath: String?
    @Binding var libraryFileNames: Set<String>

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [SoundEntry] = []
    @State private var showFolderPicker = false

    private let library = SoundLibraryService.shared

    var body: some View {
        NavigationStack {
            List {
                Section("フォルダから抽選") {
                    Toggle("フォルダを対象にする", isOn: $useFolder)
                    if useFolder {
                        Button {
                            showFolderPicker = true
                        } label: {
                            HStack {
                                Image(systemName: "folder")
                                Text(folderRelPath?.isEmpty == false ? folderRelPath! : "全体 (Documents 直下)")
                                    .lineLimit(1)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        Text("フォルダ内 (再帰) の対応形式の曲がすべて候補になります (wav / aiff / caf 推奨、mp3 / m4a / aac / flac も可)。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section {
                    if entries.isEmpty {
                        Text("インポート済みの音源はまだありません。「アラーム音」画面の下部から追加できます。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    } else {
                        HStack {
                            Button("すべて選択") {
                                libraryFileNames = Set(entries.map { $0.fileName })
                            }
                            Spacer()
                            Button("すべて解除") {
                                libraryFileNames.removeAll()
                            }
                        }
                        .buttonStyle(.borderless)
                        .font(.footnote)

                        ForEach(entries) { entry in
                            Toggle(isOn: bindingFor(entry)) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(entry.displayName)
                                        .lineLimit(1)
                                    Text(entry.fileName)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.tertiary)
                                        .lineLimit(1)
                                }
                            }
                        }
                    }
                } header: {
                    Text("個別の音源 (\(libraryFileNames.count) / \(entries.count) 選択)")
                } footer: {
                    Text("インポートした音声ファイルや音楽ライブラリから取り込んだ曲を個別に抽選対象に含められます。")
                        .font(.caption)
                }

                // 合計候補数のプレビュー (簡易表示)
                Section {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundStyle(.secondary)
                        Text(summaryLine)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("抽選対象")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完了") { dismiss() }
                }
            }
            .onAppear {
                entries = library.entries()
            }
            .sheet(isPresented: $showFolderPicker) {
                NavigationStack {
                    FolderPickerView(initialRelPath: folderRelPath) { rel in
                        folderRelPath = rel
                    }
                }
            }
        }
    }

    private var summaryLine: String {
        var parts: [String] = []
        if useFolder {
            parts.append("フォルダ: \(folderRelPath ?? "全体")")
        }
        if !libraryFileNames.isEmpty {
            parts.append("個別音源 \(libraryFileNames.count) 件")
        }
        if parts.isEmpty {
            return "⚠️ 抽選対象が未指定です。少なくとも 1 つ選んでください (未指定の時はデフォルト音になります)。"
        }
        return "抽選対象: " + parts.joined(separator: " + ")
    }

    private func bindingFor(_ entry: SoundEntry) -> Binding<Bool> {
        Binding(
            get: { libraryFileNames.contains(entry.fileName) },
            set: { on in
                if on {
                    libraryFileNames.insert(entry.fileName)
                } else {
                    libraryFileNames.remove(entry.fileName)
                }
            }
        )
    }
}
