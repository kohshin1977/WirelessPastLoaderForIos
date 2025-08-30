# H.265 Stream Receiver Debug Tool

このツールは、iOSアプリから送信されるH.265/HEVC映像ストリームを受信してデコード・表示するためのデバッグプログラムです。

## 機能

- UDP/RTPでH.265ストリームを受信
- リアルタイムでのH.265デコード
- 映像の表示
- パケットロスの検出と統計表示
- フラグメント化されたNALユニットの再構築

## セットアップ

### 1. Python環境の準備

Python 3.8以上が必要です。

```bash
# Python仮想環境の作成（推奨）
python3 -m venv venv
source venv/bin/activate  # macOS/Linux
```

### 2. 依存パッケージのインストール

```bash
cd Debug
pip install -r requirements.txt
```

注意: macOSでFFmpegのインストールが必要な場合:
```bash
brew install ffmpeg
```

## 使用方法

### 基本的な起動

```bash
python h265_receiver.py
```

デフォルトでポート5004でリッスンします。

### ポート指定

```bash
python h265_receiver.py -p 5004
```

### 操作方法

- `q`: プログラムを終了
- `s`: 統計情報を表示

## iOS側の設定

iOSアプリ側で以下の設定を行ってください：

1. IPアドレス: あなたのMacのIPアドレスを入力
   - ターミナルで確認: `ifconfig | grep inet`
2. ポート: 5004（デフォルト）

## トラブルシューティング

### 映像が表示されない場合

1. **ファイアウォールの確認**
   ```bash
   # macOSのファイアウォール設定を確認
   sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate
   ```

2. **ネットワーク接続の確認**
   - iOSデバイスとMacが同じネットワークに接続されているか確認
   - pingで疎通確認: `ping [iOSデバイスのIP]`

3. **ポートの確認**
   ```bash
   # ポート5004が使用されていないか確認
   lsof -i :5004
   ```

### デコードエラーが発生する場合

1. FFmpegの再インストール
   ```bash
   brew reinstall ffmpeg
   pip uninstall av
   pip install av --no-cache-dir
   ```

2. パケットロスの確認
   - 統計情報（`s`キー）でパケットロス率を確認
   - 高いパケットロス率の場合、ネットワーク品質を改善

## 統計情報の見方

- **Packets received**: 受信したRTPパケット数
- **Bytes received**: 受信した総バイト数
- **Frames decoded**: デコードされたフレーム数
- **Lost packets**: 検出されたパケットロス数
- **Packet loss rate**: パケットロス率（%）

## 技術詳細

### RTPパケット処理

- RTPヘッダーの解析
- H.265 NALユニットタイプの識別
- FU (Fragmentation Unit) の再構築
- AP (Aggregation Packet) の分解

### H.265デコード

- PyAV (FFmpegバインディング) を使用
- VPS/SPS/PPSパラメータセットの処理
- フレーム境界の検出とバッファリング

## デバッグモード

詳細なログを有効にする場合、コード内の該当箇所のコメントを外してください：

```python
# デバッグ出力を有効化
print(f"NAL type: {nal_type}, size: {len(nal_data)}")
```