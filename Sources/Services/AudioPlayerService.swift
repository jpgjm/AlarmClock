//
//  AudioPlayerService.swift
//  AlarmClock
//
//  指定フォルダ (or Documents 直下) から .flac / .mp3 / .aac / .wav / .m4a を
//  再帰走査してシャッフル → AVQueuePlayer で連続再生する。
//  フェードインは Timer で volume を線形に上げていく。
//
//  バックグラウンド再生と、他アプリの音楽より優先して鳴らす目的で
//  AVAudioSession は .playback + .mixWithOthers 無し (= 割り込み) で設定する。
//

import AVFoundation
import Combine
import Foundation
import MediaPlayer

@MainActor
final class AudioPlayerService: ObservableObject {

    static let shared = AudioPlayerService()

    private let audioExtensions: Set<String> = ["flac", "mp3", "aac", "wav", "m4a"]

    private var queuePlayer: AVQueuePlayer?
    private var itemsBackup: [AVPlayerItem] = []  // ループ用に元リストを保持
    private var endObserver: NSObjectProtocol?

    @Published private(set) var isPlaying: Bool = false
    @Published private(set) var currentTitle: String = ""
    @Published private(set) var currentArtist: String = ""

    private var fadeTimer: Timer?
    private var targetVolume: Float = 1.0

    // MARK: - オーディオセッション

    private func activateAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback,
                                mode: .default,
                                options: [.duckOthers])
        try session.setActive(true, options: [])
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance()
            .setActive(false, options: .notifyOthersOnDeactivation)
    }

    // MARK: - ファイル列挙

    private func documentsURL() -> URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    /// 初回起動時に `Documents/AlarmSound/` フォルダと README.txt を用意する。
    /// フォルダが既に存在してもエラーにしない。README.txt はユーザーが書き換えた場合を
    /// 尊重して、既に存在する場合は何もしない。
    func ensureAlarmSoundFolder() {
        let fm = FileManager.default
        let folder = documentsURL().appendingPathComponent("AlarmSound", isDirectory: true)
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            debugPrint("Failed to create AlarmSound folder: \(error)")
            return
        }

        let readme = folder.appendingPathComponent("README.txt")
        if fm.fileExists(atPath: readme.path) { return }

        let text = """
        このフォルダに再生したいオーディオファイルを入れてください。

        対応形式: .flac / .mp3 / .aac / .wav / .m4a
        サブフォルダを作って整理しても構いません。フォルダ内 (再帰) からランダムに選ばれて再生されます。

        アラーム発火時、ロック画面や Dynamic Island に「音楽で起きる」ボタンが表示されます。
        そのボタンを押すとこのアプリが起動し、ここに入っているファイルからランダム再生が始まります。

        ファイルの入れ方:
          - iPhone/iPad の「ファイル」アプリで「このデバイス内」→「AlarmClock」→「AlarmSound」に置く
          - AirDrop や LocalSend など、任意の転送手段で AlarmClock のフォルダに保存

        このファイル (README.txt) は削除しても構いません。
        """
        do {
            try text.write(to: readme, atomically: true, encoding: .utf8)
        } catch {
            debugPrint("Failed to write README.txt: \(error)")
        }
    }

    /// 指定フォルダ配下 (再帰) の対応音声ファイル URL 一覧。
    func collectAudioFiles(folderRelPath: String?) -> [URL] {
        let root = documentsURL()
        let target: URL
        if let rel = folderRelPath, !rel.isEmpty {
            target = root.appendingPathComponent(rel)
        } else {
            target = root
        }

        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDir),
              isDir.boolValue else {
            return []
        }

        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: target,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in true }
        ) else {
            return []
        }

        var out: [URL] = []
        for case let url as URL in enumerator {
            let ext = url.pathExtension.lowercased()
            if audioExtensions.contains(ext) {
                out.append(url)
            }
        }
        return out
    }

    /// Apple Music ライブラリの persistentID 群から、再生可能な `assetURL` を解決する。
    /// - 見つからない曲 (削除された等) は結果に含まれない。
    /// - DRM 保護されたクラウド専用曲は `assetURL` が nil のためスキップ。
    /// - iCloud/クラウドライブラリの曲でも「デバイスにダウンロード済み」なら URL が取れる。
    func resolveLibraryAssetURLs(ids: [UInt64]) -> [URL] {
        guard !ids.isEmpty else { return [] }
        var out: [URL] = []
        for id in ids {
            let query = MPMediaQuery.songs()
            query.addFilterPredicate(MPMediaPropertyPredicate(
                value: NSNumber(value: id),
                forProperty: MPMediaItemPropertyPersistentID
            ))
            if let item = query.items?.first, let url = item.assetURL {
                out.append(url)
            }
        }
        return out
    }

    /// persistentID から MPMediaItem を取得 (存在チェック / タイトル表示に使う)。
    nonisolated static func mediaItem(for id: UInt64) -> MPMediaItem? {
        let query = MPMediaQuery.songs()
        query.addFilterPredicate(MPMediaPropertyPredicate(
            value: NSNumber(value: id),
            forProperty: MPMediaItemPropertyPersistentID
        ))
        return query.items?.first
    }

    /// Apple Music ライブラリへの読み取り権限。初回は許可ダイアログが出る。
    static func requestMusicLibraryAuthorization() async -> MPMediaLibraryAuthorizationStatus {
        return await withCheckedContinuation { cont in
            MPMediaLibrary.requestAuthorization { status in
                cont.resume(returning: status)
            }
        }
    }

    static var musicLibraryAuthorizationStatus: MPMediaLibraryAuthorizationStatus {
        MPMediaLibrary.authorizationStatus()
    }

    // MARK: - 再生制御

    /// 指定フォルダの音楽 + Apple Music ライブラリの選択曲をシャッフル → 連続再生。
    /// - Parameters:
    ///   - folderRelPath: Documents 配下のフォルダ (nil = 全体、空 = 全体)
    ///   - musicLibraryIDs: Apple Music ライブラリの MPMediaEntityPersistentID 配列
    /// - Returns: 実際に再生対象となったトラック数 (フォルダ + ライブラリ解決成功分の合計)
    @discardableResult
    func playRandom(folderRelPath: String?,
                    musicLibraryIDs: [UInt64] = [],
                    volume: Double,
                    fadeInSeconds: Int) -> Int {
        stop()  // 既存再生を止める

        // フォルダの音楽ファイル URL
        var urls = collectAudioFiles(folderRelPath: folderRelPath)

        // Apple Music ライブラリの URL を解決して追加
        // (ユーザーがライブラリから削除した曲は取得できないので、静かにスキップ)
        urls.append(contentsOf: resolveLibraryAssetURLs(ids: musicLibraryIDs))

        guard !urls.isEmpty else { return 0 }
        urls.shuffle()

        do {
            try activateAudioSession()
        } catch {
            debugPrint("AVAudioSession activate failed: \(error)")
        }

        let items = urls.map { AVPlayerItem(url: $0) }
        itemsBackup = items
        let player = AVQueuePlayer(items: items)
        player.actionAtItemEnd = .advance
        queuePlayer = player

        targetVolume = Float(max(0, min(1, volume)))

        // 最後の曲が終わったらキューを再構築してループ
        endObserver = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: nil,
            queue: .main
        ) { [weak self] note in
            Task { @MainActor in
                self?.handleItemEnd(note)
            }
        }

        // 現在曲のタイトルを反映
        observeCurrent()

        if fadeInSeconds > 0 {
            player.volume = 0
            player.play()
            startFadeIn(seconds: fadeInSeconds)
        } else {
            player.volume = targetVolume
            player.play()
        }

        isPlaying = true
        return urls.count
    }

    private func handleItemEnd(_ note: Notification) {
        guard let player = queuePlayer else { return }
        // 全曲終了時はループとして itemsBackup を再度シャッフルして詰め直す
        if player.items().isEmpty {
            var next = itemsBackup.map { AVPlayerItem(asset: $0.asset) }
            next.shuffle()
            for item in next {
                player.insert(item, after: nil)
            }
            player.play()
        }
        observeCurrent()
    }

    private func observeCurrent() {
        guard let asset = queuePlayer?.currentItem?.asset as? AVURLAsset else {
            currentTitle = ""
            currentArtist = ""
            return
        }
        // 高速: URL 名前をそのまま表示 (メタデータ非同期読みは重い)
        currentTitle = asset.url.deletingPathExtension().lastPathComponent
        currentArtist = ""

        // タグから取れるなら差し替える (非同期)
        Task { [weak self] in
            do {
                let metas = try await asset.load(.commonMetadata)
                var title: String?
                var artist: String?
                for m in metas {
                    switch m.commonKey {
                    case .commonKeyTitle:
                        if let s = try? await m.load(.stringValue) { title = s }
                    case .commonKeyArtist:
                        if let s = try? await m.load(.stringValue) { artist = s }
                    default:
                        break
                    }
                }
                await MainActor.run {
                    if let t = title, !t.isEmpty { self?.currentTitle = t }
                    if let a = artist { self?.currentArtist = a }
                }
            } catch {
                // 何もしない: ファイル名フォールバックのまま
            }
        }
    }

    private var fadeStepIndex: Int = 0
    private var fadeTotalSteps: Int = 1

    private func startFadeIn(seconds: Int) {
        fadeTimer?.invalidate()
        let stepInterval: TimeInterval = 0.2
        fadeTotalSteps = max(1, Int(Double(seconds) / stepInterval))
        fadeStepIndex = 0
        // Timer.scheduledTimer のクロージャは @Sendable @escaping で、Swift 6 では
        // MainActor 隔離のプロパティを直接触れない。Timer は main run loop で発火するため
        // `MainActor.assumeIsolated` で安全に main actor コンテキストに入る。
        fadeTimer = Timer.scheduledTimer(withTimeInterval: stepInterval, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.fadeStepIndex += 1
                let v = Float(self.fadeStepIndex) / Float(self.fadeTotalSteps) * self.targetVolume
                self.queuePlayer?.volume = min(self.targetVolume, v)
                if self.fadeStepIndex >= self.fadeTotalSteps {
                    t.invalidate()
                    self.fadeTimer = nil
                }
            }
        }
    }

    /// スライダー等でユーザーが音量を変更した時。フェードインは中断する。
    func setVolume(_ v: Double) {
        fadeTimer?.invalidate()
        fadeTimer = nil
        targetVolume = Float(max(0, min(1, v)))
        queuePlayer?.volume = targetVolume
    }

    func stop() {
        fadeTimer?.invalidate()
        fadeTimer = nil
        queuePlayer?.pause()
        queuePlayer?.removeAllItems()
        queuePlayer = nil
        itemsBackup = []
        if let o = endObserver {
            NotificationCenter.default.removeObserver(o)
            endObserver = nil
        }
        isPlaying = false
        currentTitle = ""
        currentArtist = ""
        deactivateAudioSession()
    }
}
