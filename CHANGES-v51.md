# v51 の変更点

**スヌーズを `.custom` にする設定を追加しました。既定はオフです。**

| ファイル | 内容 |
|---|---|
| `Sources/Services/AlarmService.swift` | `useCustomSnooze` を追加。スヌーズの behavior と secondaryIntent を切り替え |
| `Sources/Views/AlarmEditView.swift` | 「スヌーズの方式 (検証用)」セクションを追加 |
| `Handler/LCGuestHandler.swift` | `action = "snooze"` を実装。`stop()` + 再鳴動の登録 |

---

## なぜ入れたか

v50 の実測で、パッチ版 LiveContainer の dylib から AlarmKit が見えることが
確認できました。

```
AlarmKit: auth=authorized count=1 [1015A3A3:scheduled]
```

`authorized` かつ登録済みのアラームが取れているので、この dylib は
LiveContainer のクライアントとして扱われています。つまり
`AlarmManager.shared.stop(id:)` が呼べます。

`.custom` にすると Issue に**実害**を書けるようになります。

```
1. スヌーズボタンを押してもアラームが鳴り止まない       ← .custom で初めて再現
2. 停止・スヌーズを起点としたプログラムが実行されない
```

---

## 危険なので既定はオフです

`.custom` は Intent 自身が `stop()` を呼ぶ契約です。Intent が解決されない
環境 (**素の LiveContainer**) では誰も止めないため、
**アラームが鳴り止まなくなります**。

| 環境 | `.custom` の挙動 |
|---|---|
| 直インストール | アプリ内の Intent が解決 → 止まる |
| **素の LiveContainer** | **解決されない → 止まらない** |
| パッチ版 LiveContainer | dylib が `stop()` を呼ぶ → 止まる |

真ん中が Issue で示したい問題です。

### 設定場所

アラーム編集画面 > 「スヌーズの方式 (検証用)」

スヌーズが有効なときだけ表示されます。オンにすると赤字の警告が出ます。
**アプリ全体に適用**され、変更後に登録し直したアラームから有効になります。

### 検証時の注意

- **日中に、短い時間で試してください**
- 止まらなくなったら LiveContainer をタスクキルすると止まるはずです
  (未確認。アラート表示はシステム側なので効かない可能性もあります)
- 最終手段はアラームを削除するか、端末を再起動する形になります

---

## ハンドラのスヌーズ処理

```swift
case "snooze":
    stopForSnooze(payload: payload)   // stop() → 再鳴動を登録
    // そのあと共通の抽選処理へ
```

1. `AlarmManager.shared.stop(id:)` で鳴っているアラートを止める
2. 指定分後のカウントダウンを別 ID で登録する
3. 抽選して音源を差し替える (停止ボタンと同じ)

`stop()` が失敗した場合はログに残し、抽選だけ続けます。

### 既知の制限

再鳴動用の一時アラームはアプリ側の一覧に存在しません。スヌーズ待機中に
アプリを開くと `syncSchedule` の削除ループに巻き込まれて消える可能性が
あります。検証用として許容しています。

### 型の都合

dylib ターゲットは `Sources/` をコンパイルしないので、`AlarmClockMetadata` も
`LCGuestIntent` も参照できません。そのため

- メタデータは `SnoozeMetadata` を `Handler/` 内に定義
- `AlarmConfiguration` は Intent を渡さない overload を使用

としています。

---

## 検証手順

### 1. 既定 (オフ) のまま動作確認

v50 と同じ結果になるはずです。停止ボタンで 3 環境が分かれます。

### 2. `.custom` をオンにして再登録

トグルを入れたあと、**アラームを一度編集して登録し直してください**。
既存の登録は古い設定のままです。

### 3. スヌーズを押す

| 環境 | 期待 |
|---|---|
| 直インストール | 止まる。診断ログに `[停止ボタン] LCGuestIntent (アプリ内) を実行` |
| 素の LiveContainer | **止まらない** ← 再現したい問題 |
| パッチ版 LiveContainer | 止まる。`lc-guest-intent.log` に `スヌーズ: stop() 成功` |

パッチ版のログはこうなるはずです。

```
[…] AlarmHandler: 入りました action=snooze
[…] AlarmHandler:   AlarmKit: auth=authorized count=1 [...]
[…] AlarmHandler:   スヌーズ: stop() 成功 id=1015A3A3
[…] AlarmHandler:   スヌーズ: 5 分後の再鳴動を登録 id=XXXXXXXX
[…] AlarmHandler:   差し替えました … (候補 18 曲中、履歴により N 曲を除外)
```

**検証が終わったらトグルをオフに戻してください。**
