# v49 の変更点

診断できない状態になっていたのを直しました。**機能の変更はありません。**

| ファイル | 内容 |
|---|---|
| `Shared/SoundShuffle.swift` | 履歴ファイル名を `sound-history.json` に (隠しファイルをやめた) |
| `Handler/LCGuestHandler.swift` | 入口で必ず 1 行記録する |

LiveContainer 側も rev15 に上げてください (ホストの記録を復活させています)。

---

## 1. 履歴ファイルを見えるようにしました

v48 は `.sound-history.json` という隠しファイルでした。
ファイルアプリでは既定で見えないため、中身を確認できませんでした。

```
.sound-history.json  →  sound-history.json
```

**旧ファイルがあれば自動で移行します。** 読み込み時に一度だけリネームし、
新旧が両方ある場合は旧を削除します。履歴は失われません。

### 場所

```
ファイル > このデバイス内 > LiveContainer >
  Data > Application > <コンテナUUID> > Documents > sound-history.json
```

中身はこの形です。

```json
{ "194ED9EC-2336-4B0D-A7FF-1199C4FD410A": ["11. ANZIE - こたつとみかんと.flac", …] }
```

配列が伸びていれば履歴が積み上がっています。

## 2. ハンドラの入口で必ず記録します

```swift
HandlerTrace.record("入りました action=\(actionText)")
```

これが無いと

- LiveContainer から呼ばれなかった
- 呼ばれたが早期 return した

の区別がつきませんでした。陽性対照として置きます。

---

## 判定表 (rev15 と組み合わせて)

停止ボタンのあと `ファイル > LiveContainer > lc-guest-intent.log` を見ます。

| ログ | 意味 |
|---|---|
| 何も出ない | Intent が解決されていない。LiveContainer が rev15 か確認 |
| `invoked handler=AlarmClockGuestPerform` のみ | Intent は解決された。次の行を見る |
| `… が見つかりません` | dylib が注入されていない or 署名されていない |
| `AlarmHandler: 入りました action=reshuffle` | **ハンドラまで到達** |
| `AlarmHandler: 差し替えました …` | **成功** |
| `AlarmHandler: 入りました` の後に別のメッセージ | payload かパスの問題。メッセージが理由 |

## 前回の状況について

`lc-guest-intent.log` が空だったのは、**rev14 でホスト側のファイル記録を
削ってしまったから**です。`NSLog` だけにしていました。

rev15 で戻しています。ただし本家へ PR を出すときは削る予定です
(ホストの Documents にログを作るのは、汎用の仕組みとしては余計なので)。
その旨をコードのコメントに書いてあります。

## 確認のお願い

**抽選元を 5 曲以上にしてください。**

現在 2 曲なので、除外は常に 1 曲で頭打ちです。

```
履歴により 1 曲を除外   ← 8 回とも同じ
```

これでは履歴が共有されているかを数字から判断できません。
5 曲以上なら除外数が 1 → 2 → 3 と積み上がるので、そこで初めて確認できます。
