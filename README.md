# AlarmClock (iOS 26+ / AlarmKit)

指定したフォルダ内の音楽ファイル (FLAC / MP3 / AAC / WAV / M4A) を **ランダム再生する目覚まし時計**。信頼性は AlarmKit に完全に委ねているため、サイレントモード貫通・ロック画面・Dynamic Island・Apple Watch でも鳴る。

## 主な特徴

- **AlarmKit** で確実に鳴らす (iOS 26+)。ローカル通知の 30 秒制約や「アプリを終了すると鳴らない」問題がない。
- **Live Activity Widget Extension** を同梱。ロック画面 / Dynamic Island / ステータスバーの ⏰ アイコンが正しく表示される。
- **Apple Music ライブラリ対応**: iOS 内蔵「ミュージック」アプリのライブラリから曲を **複数選択** して、アラーム発火時のランダム再生プールに追加できる。フォルダ内音源と混ぜて再生することも可能。
- **明後日アラーム対応**: `.fixed(Date)` スケジュールを使い、24 時間先までしか設定できない iOS 標準の制約を超えて、任意の日時 (明後日以降でも) を設定できる。
- **曜日繰り返し / 特定日 1 回のみ** の 2 モードをサポート。
- **音楽ランダム再生**: 発火時、アプリがフォアグラウンドにあれば AlarmItem に紐付いたフォルダから **ランダム再生 (シャッフル + ループ)** が自動開始する。
- **音量スライダー / フェードイン / スヌーズ** をアラームごとに設定可能。
- **3 層タイムゾーン補正** で明後日以降のアラームでも TZ 変更に追従。
- **idempotent スケジュール同期**: 既に AlarmKit 側で `.scheduled` 状態のアラームは、内容が変わっていなければ再登録しない。
- **エラー UI**: AlarmKit の認可拒否 / スケジュール失敗を画面上部のバナーで通知。実際のエラー内容も表示。

## ファイル構成

`flutter create` 相当を xcodegen で実現。コミットするのはソースと `project.yml` だけ。

```
AlarmClock/
├── project.yml                                # xcodegen 用プロジェクト定義 (App + Widget Ext の 2 ターゲット)
├── .github/workflows/build-ipa.yml            # xcodegen → xcodebuild → IPA
├── Sources/
│   ├── App/AlarmClockApp.swift                # @main
│   ├── Models/AlarmItem.swift                 # アラーム 1 件のモデル
│   ├── Services/
│   │   ├── AlarmService.swift                 # AlarmKit ラッパ (idempotent スケジュール)
│   │   ├── AudioPlayerService.swift           # AVQueuePlayer でランダム再生
│   │   ├── AlarmStorage.swift                 # UserDefaults 保存
│   │   ├── TimeZoneWatcher.swift              # 3 層 TZ 補正
│   │   └── AlarmAppState.swift                # 中央 ObservableObject
│   ├── Shared/                                # App と Widget Ext の両方から参照
│   │   ├── AlarmClockMetadata.swift           # AlarmAttributes<Metadata> の Metadata 型
│   │   └── OpenAndPlayIntent.swift            # secondary button 用 LiveActivityIntent
│   ├── Widgets/                               # Widget Extension (Live Activity)
│   │   ├── AlarmClockWidgetBundle.swift       # @main (Widget)
│   │   └── AlarmClockLiveActivity.swift       # ActivityConfiguration
│   └── Views/
│       ├── AlarmListView.swift                # 警告バナー付き
│       ├── AlarmEditView.swift
│       ├── FolderPickerView.swift
│       ├── MusicLibraryPicker.swift
│       └── RingingView.swift
└── Resources/
    ├── Info.plist                             # App 用 (xcodegen が properties 注入)
    ├── AlarmClockWidgets-Info.plist           # Widget Ext 用 (xcodegen が properties 注入)
```

## Info.plist に注入される設定 (App)

`project.yml` の `targets.AlarmClock.info.properties` 経由:

| キー | 値 | 目的 |
|---|---|---|
| `NSAlarmKitUsageDescription` | (日本語文言) | AlarmKit 権限リクエスト時に表示 (必須) |
| `NSAppleMusicUsageDescription` | (日本語文言) | Apple Music ライブラリ読み取り時に表示 |
| `NSSupportsLiveActivities` | `true` | Live Activity 有効 (AlarmKit UI 描画に必要) |
| `UIFileSharingEnabled` | `true` | ファイルアプリからアプリ Documents を編集 |
| `LSSupportsOpeningDocumentsInPlace` | `true` | ファイルアプリからの直接編集を許可 |
| `UIBackgroundModes` | `[audio, fetch, processing]` | バックグラウンド再生 + BGAppRefresh |
| `BGTaskSchedulerPermittedIdentifiers` | `[com.example.alarmclock.tz-recheck]` | TZ 補正用 BGAppRefreshTask 識別子 |
| `CFBundleDisplayName` | `Alarm Clock` | ホーム画面表示名 |

## Entitlements

**特別な entitlement は付けていません。** 以前 `com.apple.developer.alarmkit` を追加してみましたが、これは Apple 公式には存在しない (実在するか極めて怪しい) entitlement のようで、追加すると逆に `schedule()` が `com.apple.AlarmKit.Alarm error 0` で失敗するケースが確認されたため削除しました。

AlarmKit の実機動作に必要なのは `Info.plist` の `NSAlarmKitUsageDescription` のみです。

## 使い方 (インストール後)

1. **音楽ファイルの転送**: 初回起動時に自動で `Documents/AlarmSound/` フォルダと `README.txt` が作られます。iPhone/iPad の「ファイル」アプリで「このデバイス内」→「Alarm Clock」→「AlarmSound」に `.flac` / `.mp3` / `.aac` / `.wav` / `.m4a` を置きます。AirDrop / LocalSend からも可。
2. **アラーム追加**: 右上「+」で新規作成。デフォルトは **毎日 07:00 / ラベルなし / 再生フォルダは `AlarmSound`**。
3. **フォルダ選択**: 編集画面「再生するフォルダ」でサブフォルダを選ぶと、そこ配下 (再帰) からランダム再生。デフォルトの `AlarmSound` から変更可能。
4. **時刻**: 発火するとロック画面と Dynamic Island にアラート。**「音楽で起きる」ボタン** をタップするとアプリが開き、指定フォルダからランダム再生開始。**「止める」** で普通に停止。
5. **アプリ内 RingingView** ではさらに音量スライダー、スヌーズ、停止が使える。

## AlarmKit / Live Activity について

- 単発 Alert のみ (Countdown Presentation は使わない) だが、**Live Activity Widget Extension は必須で同梱している**。iOS 26 の AlarmKit は Alerting UI (ロック画面フル・Dynamic Island・ステータスバー ⏰ アイコン) の描画に Live Activity Widget を利用するため、これが無いと `secondaryButton` (音楽で起きる) が押せない / アイコンが出ないケースがある。
- スヌーズは AlarmKit の組み込み `.snooze` behavior ではなくアプリ内画面 (RingingView) のボタンとして持ち、押下時に「N 分後の `oneShotAt` アラーム」を新規登録する形。カスタムのフォルダ設定/音量/フェードインをそのまま引き継げるため。

## スケジュール同期の挙動 (重要)

`AlarmService.syncSchedule(with:forceReregister:)` は以下のルールで動く:

| タイミング | `forceReregister` | 挙動 |
|---|---|---|
| アプリ起動 (`bootstrap`) | `false` | 既に AlarmKit 側で `.scheduled` 状態 & 内容 (時刻・曜日・ラベル) が前回と同じアラームは再登録しない (次回発火予定を保つ) |
| アラーム編集・追加 | `true` | 該当 ID を明示的に stop してから登録し直す |
| アラーム有効化 (トグル ON) | `true` | 新規登録扱い |
| アラーム無効化 (トグル OFF) | `false` | stop するだけ |
| TZ 変更検知 | `true` | `.fixed(Date)` を再計算するため強制再登録 |

内容判定用のフィンガープリントは `AlarmItem.scheduleFingerprint` で作られる (時刻・曜日・ラベル・oneShot 日時のみを含み、フォルダ・音量・スヌーズ設定などアプリ内でしか使わない値は含めない → これらを変えても AlarmKit 再登録は起きない)。

## 制約 / 既知の問題

- iOS 26 未満では動かない (AlarmKit が存在しない)。
- AlarmKit のカスタムサウンドは単一 `.caf` 固定のため「アラーム音そのものをランダム音楽に」はできない → **代わりに Alert → ボタン → アプリ起動 → 音楽再生** の流れで実現している。
- 起動権限が拒否 (`.denied`) の場合、アラームは登録できない。設定 → 通知でユーザー自身が変更する必要がある (アプリ内で警告バナー + 「設定を開く」ボタンを提示)。
- 明後日以降のアラームは `.fixed(Date)` = UTC 絶対時刻。3 層 TZ 補正でカバーしているが、飛行機の機内モード等で TZ 変更検知が遅れた場合はズレる可能性がある。

## リポジトリへの反映 (既存の `jpgjm/ipa` パターン)

1. リポジトリ内容をこの中身で丸ごと置き換え (もしくは `Sources` / `Resources` / `project.yml` / `.github` を配置)
2. コミットで GitHub Actions が起動、artifact 名は `alarm-clock-ipa`
