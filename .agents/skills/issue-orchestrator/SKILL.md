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
- ラベル自体の作成、説明、色の変更は行わない。必要なラベルが存在しない、権限不足、または更新に失敗した場合は、実装フローを続行せず、エラーを利用者へ報告する。可能なら既存ラベルを`status:blocked`へ更新して終了する。

## 手順

1. 対象Issueとリポジトリの基本情報を確認する。作業開始前に`git status --porcelain=v1 -uall`を記録する。active marker付き状態コメントがあれば、保存状態とGit・GitHubの実態を照合し、同じrun IDと保存済み再開状態を使う。新規Runは、既存状態がない場合、または利用者が以前の状態を破棄してやり直すと明示した場合だけ発行する。必要な3つの進捗ラベルが存在することを確認し、再開状態に対応するラベルへ更新する。
   新規Runだけが手順2から開始する。再開Runは、保存済み再開状態に対応する手順へ移り、完了済みのPlanner、Implementer、Reviewerを再実行しない。
2. Herdrが利用可能ならHerdrを優先し、`$issue-planner`を呼び出して実装計画を作成させる。`PLANNED`なら続行し、`BLOCKED`なら`status:blocked`へ更新して終了する。
3. Issue、計画、開始前から変更されているパスを`$issue-implementer`へ渡し、実装とテストを任せる。開始前の変更とmanifestが同じパスなら、変更を混在させず`BLOCKED`として終了する。
4. 開始前の変更、現在の変更、3つのmanifestを比較する。開始後に増えたmanifest外の変更があれば、由来を安全に説明できる場合だけ該当manifestへ記録する。説明できない変更は内容を開かず`BLOCKED`とする。
5. `status:review`へ更新し、Issue、計画、3つのmanifestの和集合内の変更（未追跡ファイルを含む）、テスト結果を、新しい`$issue-reviewer`へ渡す。
6. Reviewerが`CHANGES_REQUESTED`なら、`status:in-progress`へ戻して同じImplementerへ指摘を渡す。`IMPLEMENTED`を回収後、`status:review`へ更新し、更新された完全なmanifestとテスト結果を同じReviewerへ渡して再レビューさせる。固定回数を設けず、停滞時は`status:blocked`へ更新して終了し、利用者へ報告する。
7. Planner、Implementer、Conflict Resolver、Reviewerのいずれかが`BLOCKED`なら、停止直前の状態、保存済み再開状態、最後に検証済みのチェックポイント、blockerを状態コメントへ保存し、`status:blocked`へ更新して終了する。Reviewerが`BLOCKED`ならcommit、push、PR作成を行わない。
8. Reviewerが明示的に`APPROVED`を返した場合だけpublishへ進む。現在のbranchと既存PRの状態を確認し、default branch上または既存PRがmerge済みのbranch上なら、新しい`agent/{issue番号}-{短い説明}`branchを作成する。
9. 3つのmanifestの和集合内かつReviewerが確認した未commit変更だけを明示的にstageしてcommitする。開始前から存在した変更、manifest外の変更、未レビュー変更を含めない。
10. push前と、既存Draft PRの明示的再開時に、取得したdefault branchとIssue branchのmerge可否を読み取り専用で確認する。Gitが競合を生成しない場合はConflict Resolverを呼び出さず手順13へ進む。通常のbase更新による競合がある場合だけ`CONFLICT_RESOLUTION`へ入り、`status:in-progress`へ更新して、Orchestratorが所有するIssue branchへbaseをcommitせずにmergeし、競合状態を準備する。rebaseとforce-pushは行わない。
11. 競合がある場合は、Gitが実際に未解決ファイルを生成したことを確認し、Issue、計画、run ID、baseとhead、merge前後のSHA、競合ファイル、3つのmanifest、開始前変更、競合元PR候補、対象テストを`$issue-conflict-resolver`へ渡す。`BLOCKED`なら手順7に従う。`RESOLVED`なら、変更が競合ファイルとconflict-resolution manifestに限定され、conflict markerが残っていないことを確認する。Orchestrator自身は競合ファイルを編集しない。
12. 競合がある場合は、base mergeで自動的に取り込まれた各pathが取得済みbase SHAのblobと同一であることを検証する。同一と証明できるbase由来pathはRunのmanifestへ加えない。証明できない変更は由来に応じたmanifestへ記録できなければ`BLOCKED`とする。`status:review`へ更新し、base SHAと検証結果、競合意図の根拠、3つのmanifestの和集合、baseに対するPR差分、テスト結果を同じReviewerへ渡す。`CHANGES_REQUESTED`なら同じImplementerへ修正を渡し、同じReviewerが再レビューする。`APPROVED`後、Reviewerが確認した未commit変更だけをstageしてmerge commitを作成する。
13. `status:review`を維持したままcommitをoriginへpushし、PRがなければReviewerが作成したPR本文を使ってdefault branch向けのdraft PRを作成する。`gh pr create`では`--assignee @me`を指定し、認証中のGitHubユーザーをassigneeへ設定する。既存PRがあれば同じbranchとPRを使う。PR本文に対象Issue、変更内容、テスト結果がなければ、同じReviewerへ補完を依頼する。
14. 各役、commit、push、PR、3つのmanifest、保存状態の結果を利用者へ簡潔に報告する。

対象Issueが特定できない場合だけ、Issue番号またはURLを利用者へ確認する。

## 境界

- 自分で実装、競合ファイルの編集、またはレビューを行わない。
- Plannerを省略しない。
- 複数Issueを並列実行しない。
- `$issue-requirements-interviewer`をこの実装フローから自動で呼び出さない。
- worktreeの作成、切替、cleanupを行わない。永続Run状態は対象Issueのactive marker付き状態コメントだけで管理し、repositoryファイルへ保存しない。
- branchはレビュー済み変更のpublishと、通常のbase更新による実際のmerge conflict解消に必要な範囲だけ管理する。
- Herdr paneは3役と条件付きConflict Resolverの実行、およびOrchestratorが作成したpaneの終了に必要な範囲だけ操作する。
- Orchestratorが所有するIssue branchへbaseを取り込んで実際の競合状態を準備する場合を除き、mergeを行わない。rebase、force-push、branch削除、worktree cleanupは自動化しない。

レビュー結果、commit SHA、PR URL、残作業を報告して終了する。
