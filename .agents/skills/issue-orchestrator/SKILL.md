---
name: issue-orchestrator
description: 1件のGitHub Issue実装を進行し、issue-planner、issue-implementer、issue-reviewerを順番に呼び出す。計画、実装、レビューの責務を自分では兼務しない。
---

# Issue Orchestrator

1件のIssueについて、次の3役を順番に呼び出す。

開始前に[`references/agent-interface.md`](references/agent-interface.md)を全文読み、Outcomeと状態遷移を管理する。

```text
Issue Orchestrator
  → Issue Planner
  → Issue Implementer
  → Issue Reviewer
```

## モデル設定

直接呼び出しでは `gpt-5.6-sol` と reasoning effort `medium` を推奨する。直接呼び出し時は親モデルを切り替えられないため、実行中の親モデルがこの設定と異なっても警告や停止はしない。

Orchestratorが起動する各役は、経路を問わず次の設定を明示的に使用する。

| 役割 | モデル | reasoning effort |
| --- | --- | --- |
| Planner | `gpt-5.6-terra` | `medium` |
| Implementer | `gpt-5.6-terra` | `medium` |
| Reviewer | `gpt-5.6-sol` | `high` |

指定モデルが利用不可、または指定付き起動に失敗した場合は、別モデルへ自動切替しない。対象役を `BLOCKED` として扱い、失敗理由を利用者へ報告して終了する。

## Herdr

開始時に`HERDR_ENV=1`、`herdr`コマンドの存在、インストール済みCLIの`herdr --help`、`herdr agent --help`、`herdr pane --help`を確認する。

- Herdrが利用可能なら、Planner、Implementer、Reviewerごとに専用paneとCodex agentを用意し、`herdr agent prompt`と`herdr agent wait`で3役を順番に実行する。各役は `herdr agent start ... -- --model <model> --config model_reasoning_effort=<effort>` の形式で、上表のモデルとreasoning effortを明示して起動する。
- コマンド構文は推測せず、インストール済みCLIの各`--help`を正とする。
- ReviewerはPlanner、Implementerとは別の新しいagentで実行する。
- `herdr pane split`後は`herdr pane process-info`でforeground processがshellになるまで短時間待ち、利用可能なshell paneだと確認してから`herdr agent start`を実行する。shell promptの文字列には依存しない。
- `agent_pane_busy`の場合はpane状態を再確認し、shellがforegroundなら`agent start`を再試行する。shell以外が占有している場合は安全に操作できないためフォールバックまたは`BLOCKED`とする。
- Planner paneは計画を回収後に閉じる。Implementer paneとReviewer paneは最終的な`APPROVED`または`BLOCKED`まで保持する。
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
| Planner、Implementer、レビュー指摘の修正中 | `status:in-progress` |
| Reviewer実行中、Reviewer承認後、draft PR作成後 | `status:review` |
| いずれかの役が`BLOCKED`、またはOrchestratorが停滞を検知 | `status:blocked` |

- 状態へ入る直前にラベルを更新する。開始時はPlannerを呼び出す前に`status:in-progress`へ更新する。
- `status:in-progress`、`status:review`、`status:blocked`は排他的に扱い、更新時は他の2つを削除する。
- 種別、優先度など、`status:*`以外の既存ラベルは変更しない。
- Reviewerの`CHANGES_REQUESTED`をImplementerへ差し戻す前に`status:in-progress`へ戻し、再レビュー前に`status:review`へ更新する。
- Reviewer承認後とdraft PR作成後は`status:review`を維持する。
- ラベル自体の作成、説明、色の変更は行わない。必要なラベルが存在しない、権限不足、または更新に失敗した場合は、実装フローを続行せず、エラーを利用者へ報告する。可能なら既存ラベルを`status:blocked`へ更新して終了する。

## 手順

1. 対象Issueとリポジトリの基本情報を確認する。作業開始前に`git status --porcelain=v1 -uall`を記録する。必要な3つの進捗ラベルが存在することを確認し、対象Issueを`status:in-progress`へ更新する。
2. Herdrが利用可能ならHerdrを優先し、`$issue-planner`を呼び出して実装計画を作成させる。`PLANNED`なら続行し、`BLOCKED`なら`status:blocked`へ更新して終了する。
3. Issue、計画、開始前から変更されているパスを`$issue-implementer`へ渡し、実装とテストを任せる。開始前の変更とmanifestが同じパスなら、変更を混在させず`BLOCKED`として終了する。
4. 開始前の変更、現在の変更、Implementerの累積manifestを比較する。開始後に増えたmanifest外の変更があれば、同じImplementerへ説明またはmanifest更新を依頼する。
5. `status:review`へ更新し、Issue、計画、manifest内の変更（未追跡ファイルを含む）、テスト結果を、新しい`$issue-reviewer`へ渡す。
6. Reviewerが`CHANGES_REQUESTED`なら、`status:in-progress`へ戻して同じImplementerへ指摘を渡す。`IMPLEMENTED`を回収後、`status:review`へ更新し、更新された完全なmanifestとテスト結果を同じReviewerへ渡して再レビューさせる。固定回数を設けず、停滞時は`status:blocked`へ更新して終了し、利用者へ報告する。
7. Planner、Implementer、Reviewerのいずれかが`BLOCKED`なら`status:blocked`へ更新する。Reviewerが`BLOCKED`ならcommit、push、PR作成を行わず、理由と残作業を利用者へ報告する。
8. Reviewerが明示的に`APPROVED`を返した場合だけpublishへ進む。現在のbranchと既存PRの状態を確認し、default branch上または既存PRがmerge済みのbranch上なら、新しい`agent/{issue番号}-{短い説明}`branchを作成する。
9. Implementerのmanifest内かつReviewerが確認した変更だけを明示的にstageしてcommitする。開始前から存在した変更、manifest外の変更、未レビュー変更を含めない。
10. `status:review`を維持したままcommitをoriginへpushし、Reviewerが作成したPR本文を使ってdefault branch向けのdraft PRを作成する。`gh pr create`では`--assignee @me`を指定し、認証中のGitHubユーザーをassigneeへ設定する。PR本文に対象Issue、変更内容、テスト結果がなければ、同じReviewerへ補完を依頼する。
11. 各役、commit、push、PRの結果を利用者へ簡潔に報告する。

対象Issueが特定できない場合だけ、Issue番号またはURLを利用者へ確認する。

## 境界

- 自分で実装またはレビューを行わない。
- Plannerを省略しない。
- 複数Issueを並列実行しない。
- `$issue-requirements-interviewer`をこの実装フローから自動で呼び出さない。
- worktreeと永続状態を管理しない。
- branchはレビュー済み変更のpublishに必要な範囲だけ管理する。
- Herdr paneは3役の実行と、Orchestratorが作成したpaneの終了に必要な範囲だけ操作する。
- merge、branch削除、worktree cleanupは自動化しない。

レビュー結果、commit SHA、PR URL、残作業を報告して終了する。
