# AlarmClock (iOS 26+ / AlarmKit)

指定したフォルダ内の音楽ファイル (FLAC / MP3 / AAC / WAV / M4A) を **ランダム再生する目覚まし時計**。信頼性は AlarmKit に完全に委ねているため、サイレントモード貫通・ロック画面・Dynamic Island・Apple Watch でも鳴る。

## 主な特徴

- **AlarmKit** で確実に鳴らす (iOS 26+)。ローカル通知の 30 秒制約や「アプリを終了すると鳴らない」問題がない。
- **Apple Music ライブラリ対応**: iOS 内蔵「ミュージック」アプリのライブラリ (デバイス保存曲 / Apple Music からダウンロード済み) から曲を **複数選択** して、アラーム発火時のランダム再生プールに追加できる。フォルダ内音源と混ぜて再生することも可能。
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

## LiveContainer で動かす場合

LiveContainer はゲストアプリをホストのプロセス内で動かすため、
`Info.plist` はホストのものが参照されます。AlarmKit は
「システムデーモンがアプリの代理で鳴らす」フレームワークなので、
そのままでは動きません。

### 必要な準備

**1. LiveContainer 側**

`Info.plist` に `NSAlarmKitUsageDescription` が必要です。
**本家に取り込み済み** (LiveContainer/LiveContainer#1528) なので、
通常配布の LiveContainer をそのまま使えます。

```xml
<key>NSAlarmKitUsageDescription</key>
<string>The guest app is requesting for this permission.</string>
```

ただし停止ボタンから音源を差し替えるには、後述の `LCGuestIntent` を
持つビルドが要ります。

**2. このアプリ側**

v28 で対応済みです。`LC_HOME_PATH` 環境変数の有無で環境を判定し
(`Sources/Services/RuntimeEnvironment.swift`)、以下を自動的に切り替えます。

| 項目 | 通常インストール | LiveContainer 内 |
|---|---|---|
| 抽選元フォルダ | 自分の `Documents/AlarmSound/` | **同じ** (差し替え不要) |
| AlarmKit が読む場所 | 自分の `Library/Sounds/` | **ホストの** `Library/Sounds/` |
| `stopIntent` | `StopAndOpenIntent` | ホストの `LCGuestIntent` |
| `secondaryIntent` | `SnoozeAndOpenIntent` | なし |
| スヌーズ | `.custom` + 自前再登録 | AlarmKit ネイティブの `.countdown` |
| 停止時の再抽選 | 走る | 走る (`LCGuestIntent` 経由でヘッドレス起動) |
| BGTaskScheduler | 登録する | スキップ |

### フォルダは 2 つある (混同しやすい)

**曲を入れるのは「抽選元フォルダ」だけです。**

```
Documents/AlarmSound/          ← ユーザーが曲を置く (抽選の候補プール)
        ↓ prepareAlarmSound() が 1 曲選んでコピー
Library/Sounds/prepared-{alarmID}.flac   ← AlarmKit が実際に読む
```

`Library/Sounds/` に手で曲を置いても鳴りません。アプリがその曲を
「選んで」いないためです。この 2 つを取り違えると原因が分からなくなるので、
**診断画面に両方のパスを表示**しています (v29)。

LiveContainer 内で差し替えが必要なのは **`Library/Sounds/` の方だけ**です。
こちらは鳴動時にシステムデーモンが読みに行くため、ホストのコンテナである
必要があります。抽選元フォルダを走査するのはアプリ自身の処理なので、
`HOME` が差し替わっていてもそのまま読めます。

### ファイルアプリからたどるパス

iOS が「ファイル」アプリに公開するのは **Documents フォルダだけ**です。
LiveContainer 内では、公開されるのは **ホストの Documents** で、
ゲストのコンテナはその配下に置かれています。

```
ファイル > このデバイス内 > LiveContainer
  └ Data/Application/{ゲストUUID}/Documents/AlarmSound/   ← ここに曲を置く
```

`ファイル > LiveContainer > Library/Sounds` を作ってそこに置いても鳴りません。
それはホストの *Documents の中の* `Library/Sounds` であって、AlarmKit が読む
`<ホスト>/Library/Sounds` とは別物です。後者は Documents の外にあるため
ファイルアプリからは到達できませんが、アプリが自動でコピーするので
手で置く必要もありません。

正確なパスは**診断画面に表示**されます。長押しでコピーできます。

## 音源の差し替え方式 (v30 以降)

登録済みアラームの音源を変えるとき、**AlarmKit の登録は触らず
`prepared-{alarmID}.{ext}` の中身だけを上書き**します。

```
従来: 再抽選 → 新しい ID で登録し直す
現在: 再抽選 → 同じファイル名に別の曲を上書き (登録はそのまま)
```

利点が 3 つあります。

1. cancel / schedule の競合が起きない (v22 で差分同期にした原因そのもの)
2. LiveContainer 内でも再抽選できる
3. **抽選履歴が機能するようになった** — 履歴のキーはアラーム ID なので、
   ID が振り直されるたびにリセットされていた。実測でも
   `履歴により 0 曲を除外` が常に出ていたのが、
   `0 → 1 → 2 → 3` と積み上がるようになった

AlarmKit は**発火のたびにファイルを読み直す**ので、この方式が成立します
(登録時にコピーやキャッシュはしていない)。独立した 2 件のアラームで確認済みです。

### 制限

- 拡張子は変えられない (ファイル名を保つ必要があるため、候補も同一拡張子に限定)
- `prepared-` で始まるファイルしか上書きしない (インポート済み音源を壊さないため)
- 同じ拡張子の候補が 1 曲以下なら何もしない

### App Intents の解決 (実測で結論が変わった)

**v41 までの理解 (誤り):**

| 確認したこと | 結果 |
|---|---|
| Intent 付きで `schedule()` できるか | できる |
| ボタン押下で `perform()` が走るか | 走らない |
| `openAppWhenRun = true` でアプリが開くか | 開かない |
| スヌーズ (`.custom`) を押したとき | アラートが鳴り止まない |

**v42 で判明 (2026-09-04 実測):**

上の結果は「**ゲストが宣言した型では**」という条件付きでした。
ホスト (LiveContainer) が宣言した `LiveActivityIntent` をゲストから
渡せば、**解決されて `perform()` が走ります**。

| 条件 | 結果 |
|---|---|
| ゲストが宣言した型 | 解決されない (従来どおり) |
| **ホストが宣言した型** | **解決される** |

一致が必要なのは `persistentIdentifier` だけで、Swift のマングル名は
不一致で構いません (ホスト = `LiveContainer`、ゲスト = `AlarmClock`)。

**`.custom` は依然として使いません。** `secondaryIntent` は `nil` のままで、
スヌーズは AlarmKit ネイティブの `.countdown` にフォールバックします。
`LCGuestIntent` が解決されなかった場合にアラームを止められなくなるのを
避けるための安全策です。

## LiveContainer でアプリを開かずに曲を差し替える (v42)

### 何ができるか

**アラームを止めるたびに、次回のアラーム音が変わります。**
アプリを開く必要も、ショートカットの自動化も要りません。

```
[AlarmKit のアラート] 停止ボタン
  ↓ システムがホストの LCGuestIntent を解決。画面は点かない
LiveContainer のプロセスで perform()
  ↓ NSExtension
LiveProcess.appex
  ↓
このアプリが別プロセスで起動 → App.init() → HeadlessRunner
  ↓
prepared-{alarmID}.flac を差し替え → exit(0)
```

これは直インストール時の `StopAndOpenIntent` とほぼ同じ体験です。

### 必要なもの

`LCGuestIntent` を宣言した LiveContainer。本家に取り込まれるまでは
パッチ版が要ります。追加されるのは 1 ファイルだけです。

```
LiveContainer/LCGuestIntent.swift
```

このアプリ側は `Sources/Intents/LCGuestIntentStub.swift` を持っています。
構造の一致するスタブで、`AlarmService.schedule()` が LiveContainer 内の
ときだけ `stopIntent` に渡します。

`AlarmService.useHostGuestIntent` を `false` にすると、v41 以前の挙動
(`stopIntent` を渡さない) に戻せます。素の LiveContainer で動かす場合に
使ってください。

### 確認

停止ボタンを押したあと、次の 2 か所を見ます。

**ホスト側** — `ファイル > このデバイス内 > LiveContainer > lc-guest-intent.log`

```
[2026-09-03T22:02:04.753Z] invoked  bundleId=com.example.alarmclock.app action=reshuffle payload=F6DC9F80-…
[2026-09-03T22:02:04.9xxZ]   起動しました (requestUUID=…)
```

**ゲスト側** — `… > Data > Application > <コンテナUUID> > Documents > AlarmClockLaunched.txt`

```
reason=init  liveProcess=はい
reason=sounds-writable=はい
reason=差し替え: 05. AstroNoteS - 緊張.flac [.flac] (候補 10 曲)
reason=ヘッドレスと判断して終了します exit(0)
```

コンテナ UUID は診断画面に表示されます。

### v41 までの方式は廃止しました

ショートカットの自動化から LiveContainer の "Probe Headless Launch" を
時刻で叩く方式は不要になりました。`LCGuestIntent` で同じことが、
しかも正しい起点 (停止ボタン) からできるためです。

`HeadlessRunner` はそのまま残ります。起こされる側の処理は変わりません。

### 通常インストールでは

この仕組みは使いません。`StopAndOpenIntent` が停止した瞬間に走るので、
そちらのほうが確実です。`HeadlessRunner` は `LP_HOME_PATH` を見て判定するので、
通常起動では何もしません。

### 関係するファイル

| ファイル | 役割 |
|---|---|
| `Sources/Intents/LCGuestIntentStub.swift` | ホストの型と構造を合わせたスタブ |
| `HeadlessRunner.swift` | ヘッドレス実行の本体。他アプリへの流用元にもなる |
| `RuntimeEnvironment.swift` | 環境判定とパス解決 |
| `LaunchTrace.swift` | 画面が出ない実行の記録。唯一の観測手段 |

## リポジトリへの反映 (既存の `jpgjm/ipa` パターン)

1. リポジトリ内容をこの中身で丸ごと置き換え (もしくは 3 ファイル + Sources ディレクトリを配置)
2. コミットで GitHub Actions が起動、artifact 名は `alarm-clock-ipa`
