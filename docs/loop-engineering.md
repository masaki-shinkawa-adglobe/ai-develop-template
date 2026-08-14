# 単一IssueのLoop Engineering契約

## 目的

Issue Agent Skillsが扱う単一のGitHub Issueについて、計画、実装、レビュー、publish、CI確認を、観測可能で停止・再開可能なループとして定義する。

本書はループの不変な設計契約の単一の正とする。Issueごとに変化する実行状態は、本書やrepository内のファイルではなく、対象GitHub Issueへ保存する。

## 対象範囲

```text
Issue
  -> Planner
  -> Implementer
  -> Reviewer
       -> CHANGES_REQUESTED -> Implementer
       -> APPROVED          -> publish
  -> required CI
       -> implementation failure -> Implementer -> Reviewer -> republish
       -> no observable progress -> WAITING_FOR_CI
       -> success                -> COMPLETED
```

対象は1件のIssueに対する1つのRunである。複数Issueの発見、優先順位付け、依存順実行、並列実行、継続スケジューリングは扱わない。

## 設計の正と実行状態

- 本書は状態、遷移、証跡、停止、再開、完了の設計を定義する。
- `.agents/skills/issue-orchestrator/SKILL.md`と`references/agent-interface.md`は、本書を実行可能なAgent契約へ具体化する。
- 対象Issueの専用状態コメントは、個別Runの現在状態を保持する。
- Issueタイムライン上のチェックポイントコメントは、重要な判断履歴を保持する。
- Git、GitHub、CIの実態は保存状態より優先する。再開時は両者を照合する。

設計と実行状態を同じrepository文書へ混在させない。実行状態をrepositoryへ保存すると、複数Issue間の編集競合、状態更新のためのcommit、古い状態の残存が発生するためである。

## Run識別子

OrchestratorはPlannerを開始する前に一意なrun IDを発行する。同じIssueを中断地点から再開するときは同じrun IDを使う。利用者が以前の状態を破棄して最初からやり直すことを明示した場合だけ、新しいrun IDを発行する。

run IDの再利用や新規発行を推測で決めない。既存Runと新しい実行が競合する場合は`BLOCKED`とする。

## 状態モデル

| 状態 | 意味 | Issueラベル |
| --- | --- | --- |
| `PLANNING` | Plannerが計画を作成中 | `status:in-progress` |
| `IMPLEMENTING` | Implementerが実装または修正中 | `status:in-progress` |
| `REVIEWING` | Reviewerが独立レビュー中 | `status:review` |
| `PUBLISHING` | レビュー済み変更をcommit、pushし、Draft PRを作成中 | `status:review` |
| `WAITING_FOR_CI` | 必須CIは継続中だが、Orchestratorは待機を終了済み | `status:review` |
| `CI_REMEDIATION` | 実装起因のCI失敗を修正中 | `status:in-progress` |
| `COMPLETED` | Reviewer承認、Draft PR、必須CIの条件を満たした | `status:review` |
| `BLOCKED` | 人の判断、権限、外部状態変更、範囲外対応が必要 | `status:blocked` |

状態遷移は次に限定する。

```text
PLANNING
  -> IMPLEMENTING
  -> BLOCKED

IMPLEMENTING
  -> REVIEWING
  -> BLOCKED

REVIEWING
  -> IMPLEMENTING       # CHANGES_REQUESTED
  -> PUBLISHING         # APPROVED
  -> BLOCKED

PUBLISHING
  -> WAITING_FOR_CI
  -> CI_REMEDIATION
  -> COMPLETED
  -> BLOCKED

WAITING_FOR_CI
  -> WAITING_FOR_CI
  -> CI_REMEDIATION
  -> COMPLETED
  -> BLOCKED

CI_REMEDIATION
  -> REVIEWING
  -> BLOCKED
```

`WAITING_FOR_CI`は失敗ではない。CIを継続させたまま現在のOrchestrator実行だけを終了し、同じIssueの明示的再実行を待つ状態である。

## 専用状態コメント

専用状態コメントは次のhidden markerを1つ含む。

```html
<!-- issue-agent-run-state:v1 -->
```

AIは対象Issueのコメント一覧からmarkerを検索して状態コメントを特定する。人向けのIssue本文索引は必須としない。

状態コメントには少なくとも次を記録する。

- run ID
- 開始時刻、最終更新時刻、終了時刻
- 現在状態と最後に検証済みのチェックポイント
- Planner、Implementer、Reviewerと使用モデル
- 各AgentのOutcome
- レビュー差し戻し回数と指摘分類
- 実行したテストと成否
- Implementerの累積manifest
- branch、commit、Draft PR、head SHA
- 必須CIと各checkの状態
- 停止理由または待機理由
- 再開地点と次に行う確認
- 人の介入回数
- 取得できる場合だけtoken数と費用

会話全文、コマンド出力全文、CI生ログ、認証情報、token、秘密情報は保存しない。判断に必要な要約と、権限上安全な参照先だけを残す。

通常の細かな遷移は専用状態コメントの現在値として更新する。`BLOCKED`、再開、Reviewer承認、publish完了など、後から判断根拠になる重要なチェックポイントだけを新しいIssueコメントとして追記する。

## 停止条件

既定の停止条件は次とする。

1. Reviewerの差し戻しは最大3回とする。Issueに別の上限が明示されている場合だけ上書きする。
2. 修正を試みた後も、同じ指摘または同じテスト失敗が2回続いた場合は停止する。
3. manifest、テスト結果、指摘内容に実質的な進展がない状態が2周続いた場合は停止する。
4. 権限不足、安全性判断、Issue範囲外の変更、利用者の既存変更との競合が必要になった場合は直ちに停止する。
5. 保存状態とGit・GitHubの実態を安全に整合できない場合は停止する。

停止時は`BLOCKED`、停止条件、根拠、最後に検証済みのチェックポイント、再開に必要な判断または外部変更を保存する。承認を推測したり、未解決の失敗を成功扱いしたりしない。

## 明示的な再開

Orchestratorはバックグラウンドで自動再開しない。利用者が同じIssueを再度`$issue-orchestrator`へ渡したときだけ再開する。

再開前に次を実態から取得し、保存状態と照合する。

- 現在のbranchとworktree
- 開始前変更と累積manifest
- commitとremote branch
- Draft PRのbase、head、draft状態
- Issueの`status:*`ラベル
- 必須CIと対象head SHA

実態が保存状態と一致する場合、最後に検証済みのチェックポイントから続行する。安全に説明できる変化だけがある場合は、根拠を状態へ記録してから整合する。未把握のcommit、未レビュー変更、manifest外変更、別Runとの競合がある場合は、状態を推測で上書きせず`BLOCKED`とする。

## CIフィードバックループ

Reviewerが`APPROVED`を返した変更だけをcommit、pushしてDraft PRを作成する。その後、対象head commitの必須CIを確認する。

- 必須CIがすべて成功した場合は`COMPLETED`とする。
- 必須CIが設定されていない場合は、その事実を証跡へ記録して`COMPLETED`にできる。
- 実装起因の失敗は`CI_REMEDIATION`として同じImplementerへ返す。
- 修正後は関連テスト、同じReviewerの再レビュー、レビュー済みmanifestだけのcommit、同じbranchへのpushを経て、新しいhead SHAのCIを確認する。
- flaky、GitHub Actions障害、外部サービス障害、原因不明、`cancelled`、`timed_out`、`action_required`は自動的に成功扱いまたは無制限再実行せず、証跡を保存して`BLOCKED`とする。

CI状態は30秒ごとに確認する。jobまたはstepの開始、完了、切替を観測可能な進捗とする。取得できる場合はログ末尾のハッシュ変化を補助に使えるが、ログ行数、ログ本文、`tail`だけに依存しない。

状態と補助ログの双方に5分間変化がなければ、CIを失敗またはキャンセルせず`WAITING_FOR_CI`として現在のOrchestrator実行を終了する。PR、head SHA、確認対象check、最後に観測した状態、再開地点を保存する。再開時は同じPRとhead SHAを実態から確認し、CI確認を続行する。

CIから実行中のCodexセッションを起動または再開する通知workflowは、本契約の対象外とする。

## 完了条件

Runは次をすべて満たした場合だけ`COMPLETED`とする。

- Reviewerが明示的に`APPROVED`を返している。
- Reviewerが確認したmanifestだけがcommitされている。
- default branch向けのDraft PRが作成されている。
- PRのhead SHAと確認対象CIのhead SHAが一致している。
- 必須CIがすべて成功しているか、必須CI未設定の事実が記録されている。
- 状態コメントと完了チェックポイントが更新されている。

Draft解除、PR承認、merge、branch削除、worktree cleanupは完了条件に含めない。

## 受入シナリオ

状態遷移の判定プログラムや自動シナリオテストは追加しない。通常のBootstrap `verify`では、次の入力と期待結果がSkill契約に反映されていることを読み取り専用で確認する。実動確認は明示的に承認されたlive verifyでのみ行い、実際に通過していない経路を検証済みと報告しない。

| シナリオ | 入力 | 期待結果 |
| --- | --- | --- |
| 正常完了 | Reviewer承認、Draft PR作成、必須CI成功 | `COMPLETED` |
| 必須CIなし | Reviewer承認、Draft PR作成、必須CI未設定 | 未設定を記録して`COMPLETED` |
| レビュー差し戻し | Reviewerが`CHANGES_REQUESTED` | 同じImplementerへ戻し、同じReviewerが再レビュー |
| 差し戻し上限 | 4回目の差し戻しが必要 | `BLOCKED` |
| 同一失敗反復 | 修正後も同じ指摘またはテスト失敗が2回継続 | `BLOCKED` |
| 無進展 | manifest、テスト、指摘に変化がない状態が2周継続 | `BLOCKED` |
| 中断再開 | 保存状態と実態が一致 | 同じrun IDで最後の検証済みチェックポイントから再開 |
| 状態不一致 | 未把握commitまたは未レビュー変更あり | 上書きせず`BLOCKED` |
| CI無変化 | job、step、補助ログが5分間無変化 | CIを継続させて`WAITING_FOR_CI` |
| CI実装失敗 | 実装起因の必須check失敗 | 同じImplementer、同じReviewerを経て再push・再確認 |
| CI外部失敗 | 外部障害または原因不明 | 証跡を保存して`BLOCKED` |

## 対象外

- 複数Issueの自動発見、選択、依存順実行、並列実行
- 定期実行またはバックグラウンドスケジューラ
- 状態遷移を判定するプログラム
- CI完了イベントによるCodexの自動起動
- GitHub Actions workflow自体の作成または変更
- 会話全文、コマンド出力全文、CI生ログの永続化
- PRのDraft解除、承認、merge

## 参考

- [What Is Loop Engineering?](https://www.ibm.com/think/topics/loop-engineering)
- [AI Harness Engineering: A Runtime Substrate for Foundation-Model Software Agents](https://arxiv.org/abs/2605.13357)
- [Agentic Harness Engineering: Observability-Driven Automatic Evolution of Coding-Agent Harnesses](https://arxiv.org/abs/2604.25850)
