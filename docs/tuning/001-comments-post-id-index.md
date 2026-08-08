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

未実施。ベンチマーカー再実行後に追記する。
