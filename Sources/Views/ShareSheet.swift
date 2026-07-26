//
//  ShareSheet.swift
//  AlarmClock
//
//  UIActivityViewController (共有メニュー) を SwiftUI から呼び出すためのラッパー。
//
//  なぜ SwiftUI 標準の ShareLink を使わないか:
//    ShareLink は iPad でポップオーバーとして表示され、その表示位置は
//    呼び出し元のボタン位置に固定される。ボタンが画面端に近いと
//    ポップオーバーが画面外にはみ出し、AirDrop やアプリのアイコンが
//    見切れてしまう。位置や表示形式を SwiftUI 側から制御する手段が無い。
//
//    UIActivityViewController を直接使い `.sheet` で包むと、
//    iPad でも画面中央にモーダル表示されるため、全体が確実に収まる。
//
//  使い方:
//    .sheet(item: $shareItem) { item in
//        ShareSheet(items: [item.url])
//    }
//

import SwiftUI
import UIKit

/// 共有対象を `.sheet(item:)` に渡すための入れ物。
/// URL 自体は Identifiable ではないのでラップする。
struct ShareTarget: Identifiable {
    let id = UUID()
    let url: URL
}

struct ShareSheet: UIViewControllerRepresentable {
    /// 共有する対象 (ファイル URL やテキストなど)。
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(
            activityItems: items,
            applicationActivities: nil
        )
        // sheet の中に載せるので、iPad でもポップオーバーではなく
        // シートいっぱいに表示される。
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {
        // 更新することは無い
    }
}
