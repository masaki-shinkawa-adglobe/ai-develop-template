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
  APPROVED           -> PUBLISHING
  CHANGES_REQUESTED  -> 上限内なら同じImplementerへ差し戻し、同じReviewerが再レビュー
  BLOCKED            -> 利用者へ報告して終了

PUBLISHING
  base conflict                     -> CONFLICT_RESOLUTION
  required CI成功                 -> COMPLETED
  required CI未設定               -> 未設定の証跡を保存してCOMPLETED
  required CI進行中かつ5分無変化  -> WAITING_FOR_CI
  実装起因のrequired CI失敗       -> CI_REMEDIATION
  外部障害または原因不明          -> BLOCKED

WAITING_FOR_CI
  base conflict                     -> CONFLICT_RESOLUTION
  required CI成功                 -> COMPLETED
  required CI進行中かつ5分無変化  -> WAITING_FOR_CI
  実装起因のrequired CI失敗       -> CI_REMEDIATION
  外部障害または原因不明          -> BLOCKED

CI_REMEDIATION
  IMPLEMENTED        -> 同じReviewerが再レビュー
  BLOCKED            -> 利用者へ報告して終了
```

`WAITING_FOR_CI`で現在のOrchestrator実行が終了した後は、`ISSUE_AGENT_STATE_DIR`または`${XDG_STATE_HOME:-$HOME/.local/state}/issue-agent-runs`のlocal filesystem backendにある成果物と実態の照合に成功した場合、同じRole・指定モデルの新しいAgent instanceで再開できる。Run directoryは、認証情報・末尾の`/`・任意の`.git`を除いた正規化repository remote URLのSHA-256、Issue番号、run IDから決定的に発見する。rootとRun directoryは実効ユーザー所有の非symlink directoryかつ`0700`相当でなければならない。不在、不安全、またはdigest不一致なら公開Issueを代替にせず`BLOCKED`とする。同じImplementer・Reviewerは同一Orchestrator実行内のinstance継続だけを意味する。新instanceのReviewerは3つのmanifestの和集合を再レビューする。

OrchestratorはReviewerから`CHANGES_REQUESTED`を受けるたびに、Run全体の累積差し戻し回数を加算し、回数と指摘分類をactive marker付き状態コメントへ保存する。Issueに別の上限が明示されていなければ最大3回まで同じImplementerへ差し戻す。4回目の`CHANGES_REQUESTED`ではImplementerへ渡さず、停止直前の状態を`REVIEWING`、保存済み再開状態を`IMPLEMENTING`として、上限変更など再開に必要な人の判断を保存し、`BLOCKED`とする。Conflict Resolver後または`CI_REMEDIATION`後の再レビューも同じ累積回数へ含める。

同じ指摘または同じテスト失敗が修正後も2回続くか、manifest、テスト結果、指摘内容に実質的な進展がない状態が2周続いた場合は、差し戻し上限に達する前でも`BLOCKED`とする。

`PUBLISHING`後はDraft PRのbase branchに対するbranch protectionとrulesetが現在のPR head SHAへ要求するcheckを必須CIとして取得し、30秒ごとに確認する。必須checkを信頼できる方法で判定できない場合は未設定と推測せず`BLOCKED`とする。すべて成功した場合、または必須CI未設定の事実を記録した場合だけ、完了条件を再確認して`COMPLETED`とする。失敗したcheck、ログの安全な要約、関連テスト、レビュー済み差分からIssue実装に起因すると説明できる失敗だけを`CI_REMEDIATION`として同じImplementerへ渡し、関連テスト、同じReviewerの再レビュー、レビュー済み変更だけのcommitと同じbranchへのpushを経て、新しいhead SHAのCIを確認する。外部障害または原因不明は`BLOCKED`とし、状態と補助ログの双方が5分間無変化ならCIを継続させたまま`WAITING_FOR_CI`として現在の実行を終了する。

Orchestratorは状態遷移、差し戻し回数、CI対象SHAとcheck状態、待機・停止理由、opaque checkpoint、安全な要約、秘匿化済み整合性表現を`<!-- issue-agent-run-state:active:v1 -->`付き状態コメントへ保存する。完全fingerprint、完全な`git status --porcelain=v1 -uall`、生path、unsalted Git blob ID、検証用秘密はdeterministicに発見した安全なRun directoryだけへ保存し、公開コメントへ保存pathを含めない。安全なbackendがなければ公開コメントを代替にせず`BLOCKED`とする。`COMPLETED`は、Reviewer承認、3つのmanifestの由来とレビュー、default branch向けDraft PR、PR head SHAと確認対象CIのSHA一致、必須CIの全成功または未設定の記録を確認し、公開状態コメントと安全な完了checkpointを更新した後だけ成立する。

## 再開用成果物

OrchestratorはRoleのOutcome名だけでなく、次の安全な引き渡し内容を保存する。

- `PLANNED`: Plannerの対象範囲、実装手順、テスト
- `IMPLEMENTED`: 最新の変更内容、累積manifest、テスト結果、残作業
- `RESOLVED`: 競合意図の根拠、解消内容、conflict-resolution manifest、テスト結果
- `CHANGES_REQUESTED`: 未解決の各指摘の重要度、path、行、理由、必要な修正
- `APPROVED`: 確認結果、承認対象のworktree fingerprintまたはcommit、承認済みPR本文
- `BLOCKED`: blocker、完了済み成果物、再開に必要な判断または外部変更

参照先は決定的に発見した安全なRun directoryに限り、pane、session、Agent instance、ローカル一時ファイル、公開Issueコメントを唯一の保存先にしない。公開コメントには保存pathを含めずopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを残す。再開時に成果物または参照先を取得できない、もしくは保存digestと一致しない場合は、完了済みRoleの再実行や推測で復元せず`BLOCKED`とする。

## 変更manifest

Runは変更の由来を次の3つへ分離する。

- Implementerの累積manifest
- Conflict Resolverのconflict-resolution manifest
- 再開前の照合で由来と範囲を説明できた外部変更のreconciliation manifest

Orchestratorは開始前に`git status --porcelain=v1 -uall`を記録し、開始前から変更されているパスをImplementerへ渡す。Implementerはそのパスを変更しない。Issue実装に変更が必要な場合は、編集前に`BLOCKED`を返す。

Orchestratorは新規Run開始時と各検証済みチェックポイントでworktree fingerprintを作る。fingerprintはHEAD、`git status --porcelain=v1 -uall`の完全な結果、全変更pathのindexとworktreeのblob ID、mode、存在・削除状態を含み、未追跡ファイルもstageせず内容のblob IDを含める。完全fingerprint、完全porcelain、生path、unsalted blob ID、検証用秘密は権限制限された永続保存先だけへ保存する。公開Issueコメントにはopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを残し、安全な保存先がなければ`BLOCKED`とする。

Orchestratorはレビュー前、再開時、stage・commit前に、開始時、最後に検証済み、現在のfingerprintと3つのmanifestを比較する。開始後に増えたmanifest外の変更があれば、その由来を安全に説明できる場合だけ該当するmanifestへ記録する。manifest内でpathが同じでもblob ID、mode、存在状態のいずれかが保存後に変わっていれば同一変更とみなさず、commitや外部変更者の明示記録など不変の証跡で由来を説明できない限り、内容を開かず`BLOCKED`とする。照合前の変化をImplementerの累積manifestへ自動的に帰属させない。

初回を含む手順3、6、16の各Implementer返却後は、成果物を仮保持し、成果物またはcheckpointを更新する前に、呼出し直前、最後に検証済み、返却時のfingerprintと3つのmanifestを照合する。同一pathのidentity変化を不変の証跡で説明できた場合だけ成果物と検証済みcheckpointを更新し、説明できない場合は仮保持した成果物の内容を開かず`BLOCKED`とする。

base mergeで自動的に取り込まれ、取得済みbase SHAのblobと同一であることをOrchestratorが検証したpathは、Runが作成した変更ではないため3つのmanifestへ加えない。Reviewerにはbase SHA、blob同一性の検証結果、baseに対するPR差分を渡す。同一性を証明できないpathは通常のmanifest規則に従い、由来を説明できなければ`BLOCKED`とする。

Reviewerは`git status --porcelain=v1 -uall`とbaseに対するPR差分で変更パスを確認する。変更されたファイルの内容を読むのは3つのmanifestの和集合内だけとするが、レビュー文脈として必要な未変更の関連コードは読んでよい。Orchestratorがbase SHAとのblob同一性を検証したbase由来pathはmanifest外変更として扱わない。それ以外のmanifest外変更は、利用者の別作業や秘密情報の可能性があるため開かず、対象外変更として報告する。

Orchestratorは承認後も、現在のfingerprintがReviewer承認対象のfingerprintと一致することを確認し、3つのmanifestの和集合内かつReviewerが確認した未commit変更だけを明示的にstageする。開始前から変更済みのパス、manifest外の変更、未レビュー変更をcommitへ含めない。既存commitを含むreconciliation manifestは再stageせず、PR差分とReviewerの確認対象が3つのmanifestの和集合に一致することを検証する。
