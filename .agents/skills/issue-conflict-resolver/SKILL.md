---
name: issue-conflict-resolver
description: issue-orchestratorがbaseをIssue branchへmergeした結果、Gitが実際に生成した競合について、競合元PR・Issue・commit履歴から両側の意図を調査し、競合ファイルだけを編集して解消する。予防的なPR比較、意味上だけの不整合、通常実装、レビューには使用しない。
---

# Issue Conflict Resolver

`$issue-orchestrator`が準備した1件のmerge conflictについて、根拠を示せる両側の意図だけを統合する。

## 実行設定

Orchestratorから起動するときは、`gpt-5.6-sol`とreasoning effort `high`を明示して起動される。指定モデルが利用不可、または指定付き起動に失敗した場合は、別モデルへ自動切替せず`BLOCKED`として理由をOrchestratorへ返す。

開始前に[`../issue-orchestrator/references/agent-interface.md`](../issue-orchestrator/references/agent-interface.md)を全文読み、Conflict ResolverのInterfaceに従う。

## 入力

Orchestratorから少なくとも次を受け取る。

- 対象Issue、Plannerの計画、run ID
- baseとIssue branch、merge前後のhead SHA
- Gitが未解決として報告した競合ファイル
- 現在までのImplementer manifest、conflict-resolution manifest、reconciliation manifest
- 作業開始前から存在する変更パス
- 判明している競合元PR、関連Issue、対象テスト

不足情報はGitとGitHubから読み取り専用で取得する。対象branch、競合ファイル、または競合元を安全に特定できない場合は推測せず`BLOCKED`を返す。

## 意図の調査

1. 適用される`AGENTS.md`、対象Issue、計画、3つのmanifestを読む。
2. Gitのindexとworktreeから、実際に未解決となったファイルと両側の内容を確認する。`ours`と`theirs`の意味をbranch名だけから推測せず、Orchestratorが渡したbase、head、merge情報と照合する。
3. 競合元commitに対応するPRを特定し、現在のIssue側と競合先側について、PR本文、差分、review上の決定、関連Issueを読む。
4. 対応PRがない場合は、関連Issueとcommit履歴を調査する。
5. 競合箇所ごとに、保持すべき各側の振る舞いと根拠を整理する。新旧だけで優先順位を決めず、両立可能な意図を保持する。

PR、Issue、commit履歴から意図を十分に説明できない、根拠が矛盾する、または両立不能な場合は、コードを推測で選ばず`BLOCKED`を返す。

## 競合解消

1. Orchestratorから渡された競合ファイルだけを編集し、根拠を示せる最小の解消を行う。
2. conflict markerが残っていないことを確認する。競合外のファイル変更が必要なら、そのファイルを編集せず残作業として報告する。
3. 競合箇所に関連するテストを実行する。失敗した場合は出力を要約し、競合解消に起因する修正可能な実装不備か、意図判断を要するblockerかを区別する。
4. `git status --porcelain=v1 -uall`で、開始前変更と自分が編集した競合ファイルを照合する。
5. 変更範囲、各競合に採用した意図、その根拠、テスト結果を返す。

`RESOLVED`は競合ファイルの内容がレビュー可能になったことを示す。関連テストに修正可能な失敗が残る場合は隠さず記録し、Reviewerの判定後にImplementerが修正できるようにする。意図判断なしには安全な内容を作れない場合は`BLOCKED`とする。

## 境界

- Gitが未解決ファイルを生成していない予防的なPR比較や意味上だけの不整合を扱わない。
- 通常のIssue実装、計画変更、レビュー、承認を行わない。
- 競合ファイル以外を編集しない。
- `git add`を含むindex操作、merge、rebase、commit、push、force-push、branch、worktree操作を行わない。
- GitHub Issue、PR、ラベル、コメントを変更しない。
- 開始前から存在する利用者変更やmanifest外変更を開いたり変更したりしない。ただし競合ファイル自体が該当する場合は、編集前に`BLOCKED`を返す。
- 認証情報、会話全文、コマンド出力全文、CI生ログを出力へ含めない。

## 出力

最初の非空行に次のいずれかを返す。

- `OUTCOME: RESOLVED`
- `OUTCOME: BLOCKED`

続けてMarkdownで次だけを返す。

- `意図の根拠`: 競合箇所ごとに、採用した両側の意図とPR、Issue、commitの安全な参照先
- `解消内容`: 競合箇所をどのように統合したか
- `変更ファイル`: 自分が編集した全ファイルのリポジトリ相対パスによるconflict-resolution manifest
- `テスト結果`: 実行したテスト、成否、未実行理由
- `blocker`: なければ「なし」。`BLOCKED`では必要な判断または不足する根拠
