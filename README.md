# AlarmClock (iOS 26+ / AlarmKit)

指定したフォルダ内の音楽ファイル (FLAC / MP3 / AAC / WAV / M4A) を **ランダム再生する目覚まし時計**。信頼性は AlarmKit に完全に委ねているため、サイレントモード貫通・ロック画面・Dynamic Island・Apple Watch でも鳴る。

## 主な特徴

- **AlarmKit** で確実に鳴らす (iOS 26+)。ローカル通知の 30 秒制約や「アプリを終了すると鳴らない」問題がない。
- **明後日アラーム対応**: `.fixed(Date)` スケジュールを使い、24 時間先までしか設定できない iOS 標準の制約を超えて、任意の日時 (明後日以降でも) を設定できる。
- **曜日繰り返し / 特定日 1 回のみ** の 2 モードをサポート。
- 発火時、Alert に「**音楽で起きる**」ボタンが出る。押すとアプリが起動し、AlarmItem に紐付いたフォルダから **ランダム再生 (シャッフル + ループ)** が始まる。
- **音量スライダー / フェードイン / スヌーズ** をアラームごとに設定可能。
- **3 層タイムゾーン補正**:
  1. 起動時に `lastKnownTimeZone` と現在の TZ を比較
  2. `BGAppRefreshTask` で定期チェック
  3. `NSSystemTimeZoneDidChange` を購読
  TZ 変更を検知したら AlarmKit に再スケジュール。

## ファイル構成

`flutter create` 相当を xcodegen で実現。コミットするのはソースと `project.yml` だけ。

```
AlarmClock/
├── project.yml                       # xcodegen 用プロジェクト定義
├── .github/workflows/build-ipa.yml   # xcodegen → xcodebuild → IPA
├── Sources/
│   ├── App/AlarmClockApp.swift       # @main
│   ├── Models/AlarmItem.swift        # アラーム 1 件のモデル
│   ├── Services/
│   │   ├── AlarmService.swift        # AlarmKit ラッパ
│   │   ├── AudioPlayerService.swift  # AVQueuePlayer でランダム再生
│   │   ├── AlarmStorage.swift        # UserDefaults 保存
│   │   ├── TimeZoneWatcher.swift     # 3 層 TZ 補正
│   │   └── AlarmAppState.swift       # 中央 ObservableObject
│   ├── Intents/OpenAndPlayIntent.swift  # secondary button 用 LiveActivityIntent
│   └── Views/
│       ├── AlarmListView.swift
│       ├── AlarmEditView.swift
│       ├── FolderPickerView.swift
│       └── RingingView.swift
└── Resources/Info.plist              # xcodegen が properties を注入 (プレースホルダのみコミット)
```

## Info.plist に注入される設定

`project.yml` の `targets.AlarmClock.info.properties` 経由:

| キー | 値 | 目的 |
|---|---|---|
| `NSAlarmKitUsageDescription` | (日本語文言) | AlarmKit 権限リクエスト時に表示 (必須) |
| `UIFileSharingEnabled` | `true` | ファイルアプリからアプリ Documents を編集 |
| `LSSupportsOpeningDocumentsInPlace` | `true` | ファイルアプリからの直接編集を許可 |
| `UIBackgroundModes` | `[audio, fetch, processing]` | バックグラウンド再生 + BGAppRefresh |
| `BGTaskSchedulerPermittedIdentifiers` | `[com.example.alarmclock.tz-recheck]` | TZ 補正用 BGAppRefreshTask 識別子 |
| `CFBundleDisplayName` | `Alarm Clock` | ホーム画面表示名 |

## 使い方 (インストール後)

1. **音楽ファイルの転送**: 初回起動時に自動で `Documents/AlarmSound/` フォルダと `README.txt` が作られます。iPhone/iPad の「ファイル」アプリで「このデバイス内」→「Alarm Clock」→「AlarmSound」に `.flac` / `.mp3` / `.aac` / `.wav` / `.m4a` を置きます。AirDrop / LocalSend からも可。
2. **アラーム追加**: 右上「+」で新規作成。デフォルトは **毎日 07:00 / ラベルなし / 再生フォルダは `AlarmSound`**。
3. **フォルダ選択**: 編集画面「再生するフォルダ」でサブフォルダを選ぶと、そこ配下 (再帰) からランダム再生。デフォルトの `AlarmSound` から変更可能。
4. **時刻**: 発火するとロック画面と Dynamic Island にアラート。**「音楽で起きる」ボタン** をタップするとアプリが開き、指定フォルダからランダム再生開始。**「止める」** で普通に停止。
5. **アプリ内 RingingView** ではさらに音量スライダー、スヌーズ、停止が使える。

## AlarmKit / ライブアクティビティ について

- Countdown Presentation は使わない (単発 Alert のみ) ため、**Live Activity widget extension は不要**。ドキュメント/コミュニティ記述に沿って「For non-countdown alarms, AlarmKit should still be able to alert without a Live Activity」。
- スヌーズは AlarmKit の組み込み `.snooze` behavior ではなくアプリ内画面 (RingingView) のボタンとして持ち、押下時に「N 分後の `oneShotAt` アラーム」を新規登録する形。カスタムのフォルダ設定/音量/フェードインをそのまま引き継げるため。

## 制約 / 既知の問題

- iOS 26 未満では動かない (AlarmKit が存在しない)。
- AlarmKit のカスタムサウンドは単一 `.caf` 固定のため「アラーム音そのものをランダム音楽に」はできない → **代わりに Alert → ボタン → アプリ起動 → 音楽再生** の流れで実現している。
- 起動権限が拒否 (`.denied`) の場合、アラームは登録できない。設定 → 通知でユーザー自身が変更する必要がある。
- 明後日以降のアラームは `.fixed(Date)` = UTC 絶対時刻。3 層 TZ 補正でカバーしているが、飛行機の機内モード等で TZ 変更検知が遅れた場合はズレる可能性がある。

## リポジトリへの反映 (既存の `jpgjm/ipa` パターン)

1. リポジトリ内容をこの中身で丸ごと置き換え (もしくは 3 ファイル + Sources ディレクトリを配置)
2. コミットで GitHub Actions が起動、artifact 名は `alarm-clock-ipa`
