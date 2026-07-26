//
//  MusicPickerBridge.swift
//  AlarmClock
//
//  SwiftUI から MPMediaPickerController (音楽ライブラリ選択 UI) を呼び出すためのブリッジ。
//  SoundPickerView から音源として追加する用途 (アラーム音として使用) のみで、
//  複数選択は不可 (allowsPickingMultipleItems = false)。
//
//  選択された曲は SoundLibraryService.importFromMediaItem(_:) で
//  Library/Sounds/{UUID}.m4a に AVAssetExportSession でコピーされる。
//  Apple Music サブスクリプション曲は DRM 保護のため失敗する (assetURL == nil)。
//

import SwiftUI
import MediaPlayer

/// SwiftUI から呼び出す音楽ライブラリピッカー。単一曲を選ばせて `onPick` で返す。
struct MusicPickerBridge: UIViewControllerRepresentable {
    /// 曲が選ばれた時に呼ばれるコールバック。キャンセル時は呼ばれない。
    var onPick: (MPMediaItem) -> Void

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = false
        picker.showsCloudItems = true   // iCloud ミュージックライブラリの曲も一覧に出す
        picker.prompt = "アラーム音として使う曲を選んでください"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPick: (MPMediaItem) -> Void

        init(onPick: @escaping (MPMediaItem) -> Void) {
            self.onPick = onPick
        }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            mediaPicker.dismiss(animated: true) { [weak self] in
                if let first = mediaItemCollection.items.first {
                    self?.onPick(first)
                }
            }
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            mediaPicker.dismiss(animated: true)
        }
    }
}
