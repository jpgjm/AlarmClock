//
//  FolderPickerView.swift
//  AlarmClock
//
//  Documents 配下のサブフォルダを選ばせるピッカー。
//  「このフォルダを選ぶ」ボタンで現在ディレクトリの相対パス (ルートなら nil) を返す。
//

import SwiftUI

struct FolderPickerView: View {
    /// 選択が終わったら呼ばれる。nil = ルート (全体)。
    var onSelected: (String?) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var currentURL: URL
    private let rootURL: URL

    init(initialRelPath: String?, onSelected: @escaping (String?) -> Void) {
        self.onSelected = onSelected
        let root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.rootURL = root
        if let rel = initialRelPath, !rel.isEmpty {
            let candidate = root.appendingPathComponent(rel)
            var isDir: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDir)
            _currentURL = State(initialValue: (exists && isDir.boolValue) ? candidate : root)
        } else {
            _currentURL = State(initialValue: root)
        }
    }

    private var isAtRoot: Bool {
        currentURL.standardizedFileURL == rootURL.standardizedFileURL
    }

    private var relPath: String {
        if isAtRoot { return "" }
        let root = rootURL.standardizedFileURL.path
        let cur = currentURL.standardizedFileURL.path
        if cur.hasPrefix(root) {
            return String(cur.dropFirst(root.count).trimmingCharacters(in: CharacterSet(charactersIn: "/")))
        }
        return currentURL.lastPathComponent
    }

    private func subDirs() -> [URL] {
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: currentURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
            return contents
                .filter { url in
                    (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
        } catch {
            return []
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 現在パス + 決定ボタン
            VStack(alignment: .leading, spacing: 8) {
                Text("現在のフォルダ")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(isAtRoot ? "(全体)" : relPath)
                    .font(.headline)
                Button {
                    onSelected(isAtRoot ? nil : relPath)
                    dismiss()
                } label: {
                    Label("このフォルダを選ぶ", systemImage: "checkmark.circle.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))

            Divider()

            List {
                if !isAtRoot {
                    Button {
                        currentURL.deleteLastPathComponent()
                    } label: {
                        Label("..", systemImage: "arrow.up")
                    }
                }
                let dirs = subDirs()
                if dirs.isEmpty {
                    Text("サブフォルダがありません")
                        .foregroundStyle(.secondary)
                }
                ForEach(dirs, id: \.absoluteString) { url in
                    Button {
                        currentURL = url
                    } label: {
                        HStack {
                            Image(systemName: "folder")
                            Text(url.lastPathComponent)
                            Spacer()
                            Image(systemName: "chevron.right")
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .foregroundStyle(.primary)
                }
            }
        }
        .navigationTitle(isAtRoot ? "フォルダを選ぶ" : relPath)
        .navigationBarTitleDisplayMode(.inline)
    }
}
