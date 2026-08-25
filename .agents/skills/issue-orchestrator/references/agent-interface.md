# Issue Agent Interface

Planner、Implementer、Reviewer、Orchestratorの引き渡しにはこのInterfaceを使う。

## 共通形式

応答の最初の非空行に、役割ごとに許可されたOutcomeを1つだけ記載する。

```text
OUTCOME: <UPPER_SNAKE_CASE_VALUE>
```

本文は役割ごとの必須見出しを持つMarkdownとする。複数の事情がある場合もOutcomeは1つに絞り、詳細を本文へ記載する。優先順位は`BLOCKED`、`CHANGES_REQUESTED`、成功Outcomeの順とする。

`BLOCKED`は、人の判断、権限、外部状態の変更、またはIssue範囲を超える対応が必要で、自律的に続行できない場合だけ使用する終端状態とする。通常の不明点、修正可能な失敗、出力形式の不足には使用しない。

## 新規Run初期化

OrchestratorはPlannerを起動する前、かつIssueラベルを更新する前に、新規Runのprivate backendを初期化する。初期化は`issue-orchestrator/scripts/initialize-run.sh <Issue番号>`を使用し、成功時・安全停止時ともに次のRun情報を機械可読なJSONで受け取る。停止時に未取得の識別子は`null`とする。

| field | 契約 |
| --- | --- |
| `outcome` | 成功時は`INITIALIZED`、安全停止時は`BLOCKED` |
| `run_id` | 暗号学的に発行されたRun ID |
| `repository_id` | 認証情報を除去し、末尾`/`と任意の末尾`.git`を除いたorigin remote URLのSHA-256 |
| `issue_number` | 対象Issue番号 |
| `state` | 成功時は初期値`PLANNING`。安全停止時は初期状態が保存済みと推測しないため`null` |
| `created_at` | 成功時のUTC作成時刻。停止時は出力しない |
| `safe_summary` | 停止時の固定安全要約。成功時は出力しない |

private backendのRun directoryは`<root>/<repository_id>/<issue_number>/<run_id>`であり、初期状態はそのdirectoryの`run.json`にだけ保存する。rootは`ISSUE_AGENT_STATE_DIR`を優先し、未設定時は`${XDG_STATE_HOME:-$HOME/.local/state}/issue-agent-runs`とする。directoryの不安全性、既存Run、作成・再検証・保存の失敗では、所有者やmodeの自動修復、代替root、公開Issueへの保存を行わない。

初期化が失敗した場合、Orchestratorは`OUTCOME: BLOCKED`として、安全な要約（秘密情報、remote URL、private path、OSエラー詳細を含めない）と、取得済みならrun ID・repository ID・Issue番号を返す。この場合、ラベル更新、Plannerその他Roleの起動、公開Issueへの状態保存を行ってはならない。

OrchestratorはOutcomeが欠落または未知の場合、本文を読み、同じpaneまたは同じサブエージェントへ確認・再出力を依頼するかを判断する。ただしcommit、push、PR作成にはReviewerの明示的な`OUTCOME: APPROVED`を必須とし、承認を推測しない。

## 公開Run状態コメント

新規Runの初期化成功後、かつラベル更新前に、Orchestratorは`issue-orchestrator/scripts/public-state-comment.sh active-create`で状態コメントv1を作成する。通常遷移は`active-update`で既存コメントだけを更新する。いずれもactive markerは対象Issueにちょうど1件でなければならず、欠落、重複、API失敗、更新後の一意性未成立では状態を推測せず安全に停止する。

`BLOCKED`、保存済み状態への再開、Reviewerの`APPROVED`、publish完了では、active更新に加えて`checkpoint`でmarkerなしの監査コメントを追記する。checkpointのPOST前後で、同じRun IDの単一activeを確認する。公開入力はschemaで許可された値だけとし、private path、manifest、patch、コマンド出力、生ログ、秘密情報、private object IDを渡さない。旧Runを利用者が明示破棄する場合は、単一active確認後に`switch`を使用し、旧Run ID・旧状態・旧Run要約・破棄理由・遷移と新Run schemaを検証したうえで、旧Run checkpointのPOST、既存activeのPATCH、一意性再確認の順を崩さない。

状態コメントまたはcheckpointの操作が失敗した場合、Orchestratorはラベル更新、Role起動、publishを続行せず、公開に安全な要約だけを返す。

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

Reviewer
  APPROVED           -> publish
  CHANGES_REQUESTED  -> 同じImplementerへ差し戻し、同じReviewerが再レビュー
  BLOCKED            -> 利用者へ報告して終了
```

レビュー修正ループに固定回数は設けない。Orchestratorが同じ指摘の反復、修正不能、Issue範囲の逸脱、外部判断の必要性を検知した場合は停滞として終了し、利用者へ報告する。

## 変更manifest

Orchestratorは開始前に`git status --porcelain=v1 -uall`を記録し、開始前から変更されているパスをImplementerへ渡す。Implementerはそのパスを変更しない。Issue実装に変更が必要な場合は、編集前に`BLOCKED`を返す。

Orchestratorはレビュー前に、開始前の変更、現在の変更、Implementerのmanifestを比較する。開始後に増えたmanifest外の変更は、同じImplementerへ説明またはmanifest更新を依頼する。

Reviewerは`git status --porcelain=v1 -uall`で全変更パスを確認する。変更されたファイルの内容を読むのはmanifest内だけとするが、レビュー文脈として必要な未変更の関連コードは読んでよい。manifest外の変更は、利用者の別作業や秘密情報の可能性があるため開かず、対象外変更として報告する。

Orchestratorは承認後も、manifest内かつReviewerが確認した変更だけを明示的にstageする。開始前から変更済みのパス、manifest外の変更、未レビュー変更をcommitへ含めない。
