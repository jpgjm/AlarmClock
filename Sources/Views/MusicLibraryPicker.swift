//
//  MusicLibraryPicker.swift
//  AlarmClock
//
//  MPMediaPickerController の SwiftUI ラッパー。
//  iOS 内蔵の Music アプリのライブラリ (デバイス保存曲 + Apple Music からダウンロード済み)
//  から曲を選ばせる標準 UI を出す。
//
//  複数選択に対応: allowsPickingMultipleItems = true。
//  クラウド専用曲は showsCloudItems = false で除外 (再生できないため)。
//

import MediaPlayer
import SwiftUI
import UIKit

struct MusicLibraryPicker: UIViewControllerRepresentable {
    /// 選択が確定した時に呼ばれる。キャンセルされた場合は空配列。
    var onPicked: ([MPMediaItem]) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPicked: onPicked)
    }

    func makeUIViewController(context: Context) -> MPMediaPickerController {
        let picker = MPMediaPickerController(mediaTypes: .music)
        picker.allowsPickingMultipleItems = true
        // クラウド専用曲 (assetURL が nil のもの) は選ばせない。目覚まし発火時に再生できず
        // 「選んだのに鳴らない」体験になるのを防ぐ。
        picker.showsCloudItems = false
        picker.showsItemsWithProtectedAssets = false
        picker.prompt = "アラーム用に曲を選んでください (複数選択可)"
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: MPMediaPickerController, context: Context) {}

    final class Coordinator: NSObject, MPMediaPickerControllerDelegate {
        let onPicked: ([MPMediaItem]) -> Void

        init(onPicked: @escaping ([MPMediaItem]) -> Void) {
            self.onPicked = onPicked
        }

        func mediaPicker(_ mediaPicker: MPMediaPickerController,
                         didPickMediaItems mediaItemCollection: MPMediaItemCollection) {
            onPicked(mediaItemCollection.items)
            mediaPicker.dismiss(animated: true)
        }

        func mediaPickerDidCancel(_ mediaPicker: MPMediaPickerController) {
            onPicked([])
            mediaPicker.dismiss(animated: true)
        }
    }
}
