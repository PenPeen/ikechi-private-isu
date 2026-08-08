# comments.post_id へのインデックス追加

## 対象

pt-query-digest で Rank 1 だったクエリ。投稿一覧でコメントを取得している。

```sql
SELECT * FROM comments WHERE post_id = ? ORDER BY created_at DESC LIMIT ?
```

## 調査手順

`long_query_time = 0` で全クエリを記録した状態でベンチマーカーを実行し、ログを集計した。

```bash
docker cp private-isu-mysql-1:/var/lib/mysql/slow.log ./slow.log
pt-query-digest ./slow.log
```

## 調査結果

### 上位2本で応答時間の95.3%

```
# Rank Query ID                            Response time Calls R/Call V/M
#    1 0x624863D30DAC59FA16849282195BE09F  42.4069 67.2%  2383 0.0178  0.00 SELECT comments
#    2 0x422390B42D4DD86C7539A5F45EB76A80  17.7533 28.1%  2419 0.0073  0.00 SELECT comments
# MISC 0xMISC                               2.9459  4.7% 37723 0.0001   0.0 <26 ITEMS>
```

残り26種類は37,723回呼ばれて合計4.7%。実行回数ではなく応答時間の割合で見ると、対象はこの2本に絞られる。

### 2.34行返すために97,670行読んでいる

Rank 1 の詳細。

```
# Attribute    pct   total     min     max     avg     95%  stddev  median
# Count          5    2383
# Exec time     67     42s    17ms    30ms    18ms    18ms   769us    17ms
# Rows sent      0   5.44k       0       3    2.34    2.90    1.20    2.90
# Rows examine  48 227.28M  97.66k  97.68k  97.67k  97.04k       0  97.04k
```

Count は全体の5%なのに Exec time は67%を占める。Rows examine の stddev が 0、つまり post_id にどの値を渡しても読む行数が変わらない。絞り込みが効いていない。

### EXPLAIN

```
| type | possible_keys | key  | rows  | filtered | Extra                       |
| ALL  | NULL          | NULL | 99147 |    10.00 | Using where; Using filesort |
```

`possible_keys` が NULL で、使える候補が存在しない。comments のインデックスは PRIMARY のみ。

`filtered: 10.00` は既定の見積もりで、実測の 2.34 行と4,000倍以上ずれている。post_id の分布を知る手段がないため。

## 原因

comments に post_id を含むインデックスがなく、post_id で絞り込むたびに全99,147行を走査している。created_at 順のインデックスもないため、ORDER BY のたびに filesort が発生する。

## 対応

```sql
ALTER TABLE comments ADD INDEX idx_post_id_created_at (post_id, created_at);
```

created_at を第2カラムに含めることで filesort も解消する。post_id 単独では走査は減るが filesort が残る。

Rank 2 の `SELECT COUNT(*) FROM comments WHERE post_id = ?` も先頭カラムの post_id で解決するため、このインデックス1本で両方に効く。

## 適用後の計測

ベンチマーカーのスコアは 1287 → 14496（11.3倍）。fail は 0 のまま。

### EXPLAIN

| 列 | 適用前 | 適用後 |
|---|---|---|
| `type` | `ALL` | `ref` |
| `key` | `NULL` | `idx_post_id_created_at` |
| `rows` | 99147 | 1 |
| `filtered` | 10.00 | 100.00 |
| `Extra` | `Using where; Using filesort` | `Backward index scan` |

`ORDER BY created_at DESC` はインデックスの逆順走査で処理され、filesort が消えた。Rank 2 の `COUNT(*)` は `Using index` になり、テーブル本体を読まなくなった。

### 対象クエリ（旧 Rank 1）

| | 適用前 | 適用後 |
|---|---|---|
| Rank | 1 | 8 |
| 応答時間の割合 | 67.2% | 4.4% |
| 実行回数 | 2,383 | 25,808 |
| 合計実行時間 | 42s | 685ms |
| 1回あたり | 17.8ms | 26µs |
| Rows examine（avg） | 97,670 | 0.74 |

呼ばれる回数が10.8倍に増えたにもかかわらず、合計時間は62分の1。Rows examine が Rows sent と同値になり、無駄読みが消えた。

旧 Rank 2 の `SELECT COUNT(*) FROM comments WHERE post_id = ?` も 28.1% → 4.7%、Rows examine は 97,660 → 2.56 になった。

### 全体

| | 適用前 | 適用後 |
|---|---|---|
| クエリ総数 | 42.52k | 347.32k |
| Exec time 合計 | 63s | 16s |
| Rows sent | 984.84k | 11.24M |
| Rows examine | 468.58M | 49.39M |

返した行が11倍に増えた一方で、読んだ行は9分の1以下。examine / sent 比は 476倍 → 4.4倍。

## 次の対象

```
# Rank Query ID                            Response time Calls  R/Call V/M
#    1 0x1CD48AE21E9C97BE44D0B06948A2E5CC   4.8677 31.1%   1062 0.0046  0.00 SELECT posts
#    2 0xDA556F9115773A1A99AA0165670CE848   2.7237 17.4% 115427 0.0000  0.00 ADMIN PREPARE
```

Rank 1 は `SELECT id, user_id, body, created_at, mime FROM posts ORDER BY created_at DESC` で、LIMIT なしで全件取得している。
