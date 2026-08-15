# Issue Agent Interface

Planner、Implementer、Conflict Resolver、Reviewer、Orchestratorの引き渡しにはこのInterfaceを使う。

## 共通形式

応答の最初の非空行に、役割ごとに許可されたOutcomeを1つだけ記載する。

```text
OUTCOME: <UPPER_SNAKE_CASE_VALUE>
```

本文は役割ごとの必須見出しを持つMarkdownとする。複数の事情がある場合もOutcomeは1つに絞り、詳細を本文へ記載する。優先順位は`BLOCKED`、`CHANGES_REQUESTED`、成功Outcomeの順とする。

`BLOCKED`は、人の判断、権限、外部状態の変更、またはIssue範囲を超える対応が必要で、自律的に続行できない場合だけ使用する現在のAgent呼び出しの終端状態とする。Run自体は同じrun IDで再開できる。通常の不明点、修正可能な失敗、出力形式の不足には使用しない。

OrchestratorはOutcomeが欠落または未知の場合、本文を読み、同じpaneまたは同じサブエージェントへ確認・再出力を依頼するかを判断する。ただしcommit、push、PR作成にはReviewerの明示的な`OUTCOME: APPROVED`を必須とし、承認を推測しない。

## Planner

許可するOutcome:

- `PLANNED`
- `BLOCKED`

必須見出し:

- `対象範囲`
- `実装手順`
- `テスト`
- `blocker`

`PLANNED`はImplementerがそのまま着手できる計画が完成したことを示す。`BLOCKED`では続行に必要な判断を`blocker`へ記載する。

## Implementer

許可するOutcome:

- `IMPLEMENTED`
- `BLOCKED`

必須見出し:

- `変更内容`
- `変更ファイル`
- `テスト結果`
- `残作業またはblocker`

`変更ファイル`はIssue実装で変更した全ファイルの累積manifestとし、リポジトリ相対パスを1項目ずつ列挙する。修正サイクルごとに差分だけでなく完全なmanifestを返す。

`IMPLEMENTED`は実装がレビュー可能で、必要なテストが成功したことを示す。環境制約で実行できないテストがある場合は、制約、試行内容、代替確認を記載する。コード起因のテスト失敗は修正して再実行し、未解消のまま`IMPLEMENTED`を返さない。

## Conflict Resolver

許可するOutcome:

- `RESOLVED`
- `BLOCKED`

必須見出し:

- `意図の根拠`
- `解消内容`
- `変更ファイル`
- `テスト結果`
- `blocker`

`変更ファイル`はConflict Resolverが編集した全ファイルのconflict-resolution manifestとし、リポジトリ相対パスを1項目ずつ列挙する。`RESOLVED`は、Gitが生成した競合ファイルの内容が根拠付きで解消され、レビュー可能であることを示す。修正可能なテスト失敗は隠さず`テスト結果`へ記載し、Reviewerの判定後にImplementerが修正する。意図の根拠が不足または矛盾する、両立不能、または安全に解消できない場合は`BLOCKED`を返す。

## Reviewer

許可するOutcome:

- `APPROVED`
- `CHANGES_REQUESTED`
- `BLOCKED`

必須見出し:

- `確認結果`
- `指摘`

`CHANGES_REQUESTED`では、重要度、ファイル、行、理由、必要な修正を`指摘`へ記載する。`BLOCKED`では判定に必要な情報または判断を記載する。

`APPROVED`の場合だけ`PR本文`を追加し、次を含むdraft PR本文を作成する。

- 対象Issue
- 変更内容
- テスト結果

PRタイトルはOrchestratorがIssueタイトルから作成する。ReviewerはPR本文を作成するだけで、GitHubを変更しない。

## 状態遷移

```text
Planner
  PLANNED            -> Implementer
  BLOCKED            -> 利用者へ報告して終了

Implementer
  IMPLEMENTED        -> Reviewer
  BLOCKED            -> 利用者へ報告して終了

Conflict Resolver
  RESOLVED           -> Reviewer
  BLOCKED            -> 利用者へ報告して終了

Reviewer
  APPROVED           -> publish
  CHANGES_REQUESTED  -> 同じImplementerへ差し戻し、同じReviewerが再レビュー
  BLOCKED            -> 利用者へ報告して終了
```

レビュー修正ループに固定回数は設けない。Orchestratorが同じ指摘の反復、修正不能、Issue範囲の逸脱、外部判断の必要性を検知した場合は停滞として終了し、利用者へ報告する。

## 変更manifest

Runは変更の由来を次の3つへ分離する。

- Implementerの累積manifest
- Conflict Resolverのconflict-resolution manifest
- 再開前の照合で由来と範囲を説明できた外部変更のreconciliation manifest

Orchestratorは開始前に`git status --porcelain=v1 -uall`を記録し、開始前から変更されているパスをImplementerへ渡す。Implementerはそのパスを変更しない。Issue実装に変更が必要な場合は、編集前に`BLOCKED`を返す。

Orchestratorはレビュー前に、開始前の変更、現在の変更、3つのmanifestを比較する。開始後に増えたmanifest外の変更があれば、その由来を安全に説明できる場合だけ該当するmanifestへ記録する。説明できない変更は内容を開かず`BLOCKED`とする。

base mergeで自動的に取り込まれ、取得済みbase SHAのblobと同一であることをOrchestratorが検証したpathは、Runが作成した変更ではないため3つのmanifestへ加えない。Reviewerにはbase SHA、blob同一性の検証結果、baseに対するPR差分を渡す。同一性を証明できないpathは通常のmanifest規則に従い、由来を説明できなければ`BLOCKED`とする。

Reviewerは`git status --porcelain=v1 -uall`とbaseに対するPR差分で変更パスを確認する。変更されたファイルの内容を読むのは3つのmanifestの和集合内だけとするが、レビュー文脈として必要な未変更の関連コードは読んでよい。Orchestratorがbase SHAとのblob同一性を検証したbase由来pathはmanifest外変更として扱わない。それ以外のmanifest外変更は、利用者の別作業や秘密情報の可能性があるため開かず、対象外変更として報告する。

Orchestratorは承認後も、3つのmanifestの和集合内かつReviewerが確認した未commit変更だけを明示的にstageする。開始前から変更済みのパス、manifest外の変更、未レビュー変更をcommitへ含めない。既存commitを含むreconciliation manifestは再stageせず、PR差分とReviewerの確認対象が3つのmanifestの和集合に一致することを検証する。
