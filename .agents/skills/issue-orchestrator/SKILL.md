---
name: issue-orchestrator
description: 1件のGitHub Issue実装を進行し、issue-planner、issue-implementer、issue-reviewerと、実際のmerge conflict時だけissue-conflict-resolverを呼び出す。計画、実装、競合編集、レビューの責務を自分では兼務しない。
---

# Issue Orchestrator

1件のIssueについて、次の3役と条件付き1役を呼び出す。

開始前に[`references/agent-interface.md`](references/agent-interface.md)と[`../../../docs/loop-engineering.md`](../../../docs/loop-engineering.md)を全文読み、Outcome、Run、状態遷移を管理する。

```text
Issue Orchestrator
  → Issue Planner
  → Issue Implementer
  → Issue Conflict Resolver  # Gitが実際のmerge conflictを生成した場合だけ
  → Issue Reviewer
```

## モデル設定

直接呼び出しでは `gpt-5.6-sol` と reasoning effort `medium` を推奨する。直接呼び出し時は親モデルを切り替えられないため、実行中の親モデルがこの設定と異なっても警告や停止はしない。

Orchestratorが起動する各役は、経路を問わず次の設定を明示的に使用する。

| 役割 | モデル | reasoning effort |
| --- | --- | --- |
| Planner | `gpt-5.6-terra` | `medium` |
| Implementer | `gpt-5.6-terra` | `medium` |
| Conflict Resolver | `gpt-5.6-sol` | `high` |
| Reviewer | `gpt-5.6-sol` | `high` |

指定モデルが利用不可、または指定付き起動に失敗した場合は、別モデルへ自動切替しない。対象役を `BLOCKED` として扱い、失敗理由を利用者へ報告して終了する。

## Herdr

開始時に`HERDR_ENV=1`、`herdr`コマンドの存在、インストール済みCLIの`herdr --help`、`herdr agent --help`、`herdr pane --help`を確認する。

- Herdrが利用可能なら、Planner、Implementer、Reviewerと、必要時のConflict Resolverごとに専用paneとCodex agentを用意し、`herdr agent prompt`と`herdr agent wait`で実行する。各役は `herdr agent start ... -- --model <model> --config model_reasoning_effort=<effort>` の形式で、上表のモデルとreasoning effortを明示して起動する。
- コマンド構文は推測せず、インストール済みCLIの各`--help`を正とする。
- ReviewerはPlanner、Implementerとは別の新しいagentで実行する。
- `herdr pane split`後は`herdr pane process-info`でforeground processがshellになるまで短時間待ち、利用可能なshell paneだと確認してから`herdr agent start`を実行する。shell promptの文字列には依存しない。
- `agent_pane_busy`の場合はpane状態を再確認し、shellがforegroundなら`agent start`を再試行する。shell以外が占有している場合は安全に操作できないためフォールバックまたは`BLOCKED`とする。
- Planner paneは計画を回収後に閉じる。Conflict Resolver paneは`RESOLVED`または`BLOCKED`を回収後に閉じる。Implementer paneとReviewer paneは最終的な`APPROVED`または`BLOCKED`まで保持する。
- `CHANGES_REQUESTED`では同じImplementer paneへ指摘を渡し、修正後は同じReviewer paneへ再レビューを依頼する。
- Outcomeが欠落または未知の場合は、必要に応じて同じpaneへ確認またはInterfaceに沿った再出力を依頼する。
- 最終状態を回収したら、その役のために作成したpaneを`herdr pane close`で閉じる。
- Orchestrator自身のpaneと、開始前から存在したpaneは閉じない。paneを閉じられない場合は利用者へ報告する。
- `HERDR_ENV=1`でない、`herdr`が存在しない、またはHerdrを安全に操作できない場合は、Codexのサブエージェント機能へフォールバックする。
- サブエージェントへフォールバックした場合は、各役の `spawn_agent` で `fork_turns: "none"`、上表の `model`、`reasoning_effort` を明示する。`fork_turns` の省略または `all` は使用しない。同じInterfaceを使い、修正と再レビューは同じImplementer、Reviewerへfollow-upして、起動時のagentと設定を維持する。
- Herdrの利用有無とフォールバック理由を利用者へ報告する。

## Issueラベル

対象Issueの進捗に合わせ、次の`status:*`ラベルを更新する。

| 状態 | ラベル |
| --- | --- |
| Planner、Implementer、Conflict Resolver、レビュー指摘の修正中 | `status:in-progress` |
| Reviewer実行中、Reviewer承認後、draft PR作成後 | `status:review` |
| いずれかの役が`BLOCKED`、またはOrchestratorが停滞を検知 | `status:blocked` |

- 状態へ入る直前にラベルを更新する。開始時はPlannerを呼び出す前に`status:in-progress`へ更新する。
- `status:in-progress`、`status:review`、`status:blocked`は排他的に扱い、更新時は他の2つを削除する。
- 種別、優先度など、`status:*`以外の既存ラベルは変更しない。
- Reviewerの`CHANGES_REQUESTED`をImplementerへ差し戻す前に`status:in-progress`へ戻し、再レビュー前に`status:review`へ更新する。
- Reviewer承認後とdraft PR作成後は`status:review`を維持する。
- `CI_REMEDIATION`へ入る前に`status:in-progress`へ戻し、再レビュー前に`status:review`へ更新する。`WAITING_FOR_CI`と`COMPLETED`では`status:review`を維持する。
- ラベル自体の作成、説明、色の変更は行わない。必要なラベルが存在しない、権限不足、または更新に失敗した場合は、実装フローを続行せず、エラーを利用者へ報告する。可能なら既存ラベルを`status:blocked`へ更新して終了する。

## Run状態

- Use the local filesystem state backend defined by `docs/loop-engineering.md`: resolve `ISSUE_AGENT_STATE_DIR`, or `${XDG_STATE_HOME:-$HOME/.local/state}/issue-agent-runs` when unset; normalize the repository remote URL by removing credentials, a trailing `/`, and an optional `.git`; SHA-256 it; and discover the Run directory as `<root>/<repository-id>/<Issue番号>/<run ID>`. Require the root and Run directory to be effective-user-owned, non-symlink directories with no group or other access (`0700` equivalent). Do not create either directory or repair permissions. An absent, unsafe, or digest-unverifiable backend is `BLOCKED`, never a reason to use Issue comments as a substitute.
- 状態遷移の前後に、対象Issueで唯一の`<!-- issue-agent-run-state:active:v1 -->`を持つ状態コメントへ、run ID、現在状態、保存済み再開状態、各AgentのOutcome、レビュー差し戻し回数と指摘分類、branch、commit、Draft PR、head SHA、必須CI、opaque checkpoint、安全な要約、秘匿化済み整合性表現だけを保存する。3つのmanifest、完全なfingerprint、完全な`git status --porcelain=v1 -uall`、生path、unsalted Git blob ID、検証用秘密を公開Issueコメントへ保存しない。
- paneやAgent instanceなしで再開できるよう、Plannerの計画、最新Implementerの変更・テスト・残作業、未解決のReviewer指摘、Conflict Resolverの意図の根拠・解消内容・テスト、Reviewer承認と承認済みPR本文を、該当するOutcomeごとに権限制限された永続保存先へ安全な引き渡し成果物として保存する。公開コメントにはopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを残す。安全な保存先がない場合は公開コメントを代替にせず`BLOCKED`とする。
- 新規Run開始時と各検証済みチェックポイントで、HEAD、完全な`git status --porcelain=v1 -uall`、変更pathごとのindexとworktreeのblob ID、mode、存在・削除状態、未追跡ファイルのstageしない内容blob ID、および正規化表現のdigestを権限制限された永続保存先だけへ保存する。公開Issueコメントには生path、完全porcelain、unsalted blob ID、検証用秘密を残さず、再開に使うopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを記録する。
- `BLOCKED`、再開、Reviewer承認、publish完了、`COMPLETED`は、状態コメントの更新に加えてmarkerなしのチェックポイントコメントを作成する。
- 状態コメントの保存内容とGit・GitHub・CIの実態が異なる場合は実態を優先する。ただし、安全に整合できない不一致を推測で上書きせず`BLOCKED`とする。

## 手順

1. 対象Issueとリポジトリの基本情報を確認する。Run directoryを決定的に発見し、安全性とdigest検証可能性を確認してから、作業開始前にworktree fingerprintを取得する。active marker付き状態コメントがあれば、Run directoryの開始時と最新チェックポイントのfingerprint、および公開コメントのopaque checkpoint、安全な要約、秘匿化済み整合性表現をGit・GitHubの実態と照合し、同じrun IDと保存済み再開状態を使う。fingerprintのpath集合が同じでも内容digestが異なれば一致とみなさない。新規Runは、既存状態がない場合、または利用者が以前の状態を破棄してやり直すと明示した場合だけ発行する。backendが未作成・不安全・照合不能なら、公開Issueを代替にせず`BLOCKED`とする。既存状態がなければ対象Issueで唯一のactive marker付き状態コメントを作成し、以前の状態を明示的に破棄する場合は旧Runの安全なチェックポイントと公開の安全な要約を残してから既存の状態コメントを新Runの内容へ更新する。必要な3つの進捗ラベルが存在することを確認し、再開状態に対応するラベルへ更新する。
   新規Runだけが手順2から開始する。再開Runは保存済み引き渡し成果物を検証して保存済み再開状態に対応する手順へ移り、成果物の復元だけを目的に完了済みのPlanner、Implementer、Reviewerを再実行しない。必須成果物が欠落し、永続参照先も取得・digest検証できない場合は、推測やRole再実行で補わず`BLOCKED`とする。
2. Herdrが利用可能ならHerdrを優先し、`$issue-planner`を呼び出して実装計画を作成させる。`PLANNED`なら計画の引き渡し成果物を状態へ保存して続行し、`BLOCKED`なら`status:blocked`へ更新して終了する。
3. Issue、計画、開始前から変更されているパスを`$issue-implementer`へ渡し、実装とテストを任せる。開始前の変更とmanifestが同じパスなら、変更を混在させず`BLOCKED`として終了する。初回の`IMPLEMENTED`も成果物を仮保持するだけで、ここでは成果物・checkpointを更新しない。
4. 初回を含むImplementer返却後は、開始時、呼出し直前、最後に検証済み、返却時のfingerprintと3つのmanifestを比較する。開始後に増えたmanifest外の変更があれば、由来を安全に説明できる場合だけ該当manifestへ記録する。manifest内の同じpathでも保存後に内容identityが変わっていればImplementer由来と推測せず、commitや外部変更者の明示記録など不変の証跡で由来を説明できなければ、仮保持した成果物の内容を開かず`BLOCKED`とする。照合できた場合だけ、最新Implementer成果物と検証済みcheckpointを更新する。
5. `status:review`へ更新し、Issue、計画、3つのmanifestの和集合内の変更（未追跡ファイルを含む）、テスト結果を、新しい`$issue-reviewer`へ渡す。
6. Reviewerが`CHANGES_REQUESTED`なら、その差し戻しを状態コメントの累積回数へ加算し、未解決の各指摘について重要度、path、行、理由、必要な修正を引き渡し成果物として保存する。Issueに別の上限が明示されていなければ最大3回まで、`status:in-progress`へ戻して同じImplementerへ指摘を渡す。`IMPLEMENTED`を回収した直後は成果物もcheckpointも更新せず、呼出し直前、最後に検証済み、返却時のfingerprintと3つのmanifestを照合する。同一pathのidentity変化を不変の証跡で説明できず、または照合に失敗した場合は内容を開かず`BLOCKED`とする。照合に成功した場合だけ最新Implementer成果物と検証済みcheckpointを更新し、`status:review`へ更新して、更新された完全なmanifestとテスト結果を同じReviewerへ渡して再レビューさせる。4回目の差し戻しが必要になった時点ではImplementerへ渡さず、停止直前の状態を`REVIEWING`、保存済み再開状態を`IMPLEMENTING`として、上限変更など再開に必要な人の判断を保存し、`BLOCKED`とする。同じ指摘または同じテスト失敗が修正後も2回続くか、manifest、テスト結果、指摘内容に実質的な進展がない状態が2周続いた場合も`BLOCKED`とする。
7. Planner、Implementer、Conflict Resolver、Reviewerのいずれかが`BLOCKED`なら、停止直前の状態、保存済み再開状態、最後に検証済みのチェックポイント、最新worktree fingerprint、該当Roleの引き渡し成果物、blockerを権限制限された永続保存先へ保存し、公開状態コメントにはopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを残して`status:blocked`へ更新し終了する。Reviewerが`BLOCKED`ならcommit、push、PR作成を行わない。
8. Reviewerが明示的に`APPROVED`を返した場合だけ、承認証跡とReviewerが作成したPR本文を引き渡し成果物として保存してpublishへ進む。現在のbranchと既存PRの状態を確認し、default branch上または既存PRがmerge済みのbranch上なら、新しい`agent/{issue番号}-{短い説明}`branchを作成する。
9. 現在のworktree fingerprintがReviewer承認時のfingerprintと一致することを確認し、3つのmanifestの和集合内かつReviewerが確認した未commit変更だけを明示的にstageしてcommitする。開始前から存在した変更、manifest外の変更、未レビュー変更を含めない。
10. push前と、既存Draft PRの明示的再開時に、取得したdefault branchとIssue branchのmerge可否を読み取り専用で確認する。Gitが競合を生成しない場合はConflict Resolverを呼び出さず手順13へ進む。通常のbase更新による競合がある場合だけ`CONFLICT_RESOLUTION`へ入り、`status:in-progress`へ更新して、Orchestratorが所有するIssue branchへbaseをcommitせずにmergeし、競合状態を準備する。rebaseとforce-pushは行わない。
11. 競合がある場合は、Gitが実際に未解決ファイルを生成したことを確認し、Issue、計画、run ID、baseとhead、merge前後のSHA、競合ファイル、3つのmanifest、開始前変更、競合元PR候補、対象テストを`$issue-conflict-resolver`へ渡す。`BLOCKED`なら手順7に従う。`RESOLVED`なら、変更が競合ファイルとconflict-resolution manifestに限定され、conflict markerが残っていないことを確認し、意図の根拠、解消内容、manifest、テスト結果を引き渡し成果物として保存する。Orchestrator自身は競合ファイルを編集しない。
12. 競合がある場合は、base mergeで自動的に取り込まれた各pathが取得済みbase SHAのblobと同一であることを検証する。同一と証明できるbase由来pathはRunのmanifestへ加えない。証明できない変更は由来に応じたmanifestへ記録できなければ`BLOCKED`とする。`status:review`へ更新し、base SHAと検証結果、競合意図の根拠、3つのmanifestの和集合、baseに対するPR差分、テスト結果を同じReviewerへ渡す。`CHANGES_REQUESTED`なら手順6の累積回数と停止条件を適用して同じImplementerへ修正を渡し、同じReviewerが再レビューする。`APPROVED`後、承認証跡とPR本文を保存し、現在のworktree fingerprintがReviewer承認時のfingerprintと一致することを確認してから、Reviewerが確認した未commit変更だけをstageしてmerge commitを作成する。
13. `status:review`を維持したままcommitをoriginへpushし、PRがなければReviewerが作成したPR本文を使ってdefault branch向けのdraft PRを作成する。`gh pr create`では`--assignee @me`を指定し、認証中のGitHubユーザーをassigneeへ設定する。既存PRがあれば同じbranchとPRを使う。PR本文に対象Issue、変更内容、テスト結果がなければ、同じReviewerへ補完を依頼する。publish完了のチェックポイントを状態コメントとIssueタイムラインへ保存する。
14. Draft PRのbase branchに対するbranch protectionとrulesetが現在のPR head SHAへ要求するcheckを必須CIとして取得する。必須checkを信頼できる方法で判定できなければ、未設定と推測せず`BLOCKED`とする。必須CIが設定されていなければ、その事実と確認したhead SHAを状態コメントへ記録して手順17へ進む。必須CIがある場合は、check名、状態、対象SHAを保存し、30秒ごとに確認する。jobまたはstepの開始、完了、切替を進捗とし、取得できる場合だけ補助ログ末尾のハッシュ変化も使う。
15. 対象head SHAの必須CIがすべて成功した場合は手順17へ進む。状態と補助ログの双方に5分間変化がなければ、PR、head SHA、確認対象check、最後に観測した状態、再開地点を権限制限された永続保存先へ保存し、公開コメントにはopaque checkpoint、安全な要約、秘匿化済み整合性表現だけを残して、CIを継続させたまま`WAITING_FOR_CI`として現在のOrchestrator実行を終了する。明示的な再実行時は、永続成果物と実態の照合に成功した場合、同じRole・指定モデルの新しいAgent instanceでCI確認を再開できる。「同じImplementer・Reviewer」は同一Orchestrator実行内のinstance継続を意味する。flaky、GitHub Actions障害、外部サービス障害、原因不明、`cancelled`、`timed_out`、`action_required`は成功扱いや無制限再実行をせず、証跡を保存して`BLOCKED`とする。
16. 必須CIの失敗を、失敗したcheck、ログの安全な要約、関連テスト、レビュー済み差分からIssue実装に起因すると説明できる場合だけ、`CI_REMEDIATION`として`status:in-progress`へ更新し、同じImplementerへ渡す。起因を説明できなければ原因不明として手順15の`BLOCKED`を適用する。関連テストを通した`IMPLEMENTED`を回収した直後は成果物もcheckpointも更新せず、呼出し直前、最後に検証済み、返却時のfingerprintと3つのmanifestを照合する。同一pathのidentity変化を不変の証跡で説明できず、または照合に失敗した場合は内容を開かず`BLOCKED`とする。照合に成功した場合だけ最新Implementer成果物と検証済みcheckpointを更新し、`status:review`へ更新して完全なmanifestとテスト結果を同じReviewerへ渡す。`CHANGES_REQUESTED`は手順6の累積回数と停止条件を適用する。`APPROVED`後は承認証跡とPR本文を保存し、現在のworktree fingerprintがReviewer承認時のfingerprintと一致することを確認してから、Reviewerが確認した未commit変更だけをcommitして同じbranchへpushし、新しいPR head SHAについて手順14から必須CIを確認し直す。
17. Reviewer承認、3つのmanifestの由来とレビュー、default branch向けDraft PR、PR head SHAと確認対象CIのSHA一致、必須CIの全成功または未設定の記録を再確認する。すべて満たす場合だけ状態コメントを`COMPLETED`へ更新し、markerなしの完了チェックポイントをIssueへ記録する。条件不足は`COMPLETED`にせず、該当する再開状態または`BLOCKED`を保存する。
18. 各役、commit、push、PR、3つのmanifest、必須CI、最終状態、保存状態の結果を利用者へ簡潔に報告する。

対象Issueが特定できない場合だけ、Issue番号またはURLを利用者へ確認する。

## 境界

- 自分で実装、競合ファイルの編集、またはレビューを行わない。
- Plannerを省略しない。
- 複数Issueを並列実行しない。
- `$issue-requirements-interviewer`をこの実装フローから自動で呼び出さない。
- worktreeの作成、切替、cleanupを行わない。公開Run状態は対象Issueのactive marker付き状態コメントだけで管理し、完全fingerprintなどの秘匿情報は権限制限された永続保存先だけへ保存する。repositoryファイルへRun状態を保存しない。
- branchはレビュー済み変更のpublishと、通常のbase更新による実際のmerge conflict解消に必要な範囲だけ管理する。
- Herdr paneは3役と条件付きConflict Resolverの実行、およびOrchestratorが作成したpaneの終了に必要な範囲だけ操作する。
- Orchestratorが所有するIssue branchへbaseを取り込んで実際の競合状態を準備する場合を除き、mergeを行わない。rebase、force-push、branch削除、worktree cleanupは自動化しない。

レビュー結果、commit SHA、PR URL、残作業を報告して終了する。
