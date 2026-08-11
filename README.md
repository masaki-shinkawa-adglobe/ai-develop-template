# Issue Agent Skills

GitHub Issue の要件整理から実装・レビュー・Draft PR 作成までを、役割分担して進める AI 開発用 Skill 集です。

## 構成

```text
.agents/skills/
  issue-requirements-interviewer/  # 要件整理と Issue 作成
  issue-orchestrator/              # 1件の Issue 実装を進行
  issue-planner/                   # 実装計画
  issue-implementer/               # 実装とテスト
  issue-reviewer/                  # 読み取り専用レビュー
```

## 要件整理

`issue-requirements-interviewer` は、既存文書・コード・Issue・PR を調査し、利用者へのヒアリングを通じて合意した実装単位を GitHub Issue にします。実装、PR 作成、レビュー、マージは行いません。

## Issue 実装フロー

`issue-orchestrator` は1件の GitHub Issue を受け取り、次の3役を順番に呼び出します。

```text
Issue Orchestrator
  → Issue Planner
  → Issue Implementer
  → Issue Reviewer
```

- Planner は関連コードとテストを読み、実装計画だけを作成します。
- Implementer は計画に沿って実装とテストを行います。
- Reviewer は変更を編集せず、Issue の完了条件、差分、テスト結果を独立して確認します。
- Reviewer が変更を要求した場合は、同じ Implementer が修正し、同じ Reviewer が再レビューします。
- Reviewer が承認した変更だけを Orchestrator が commit・push し、GitHub CLI で Draft PR を作成します。

Orchestrator は Herdr を利用できる場合、各役を専用 pane で実行します。利用できない場合は Codex サブエージェントへフォールバックします。

## 役割別モデル

| Skill | モデル | reasoning effort |
| --- | --- | --- |
| Issue Requirements Interviewer | `gpt-5.6-sol` | `medium` |
| Issue Orchestrator | `gpt-5.6-sol` | `medium` |
| Issue Planner | `gpt-5.6-terra` | `medium` |
| Issue Implementer | `gpt-5.6-terra` | `medium` |
| Issue Reviewer | `gpt-5.6-sol` | `high` |

Requirements Interviewer と Orchestrator の設定は、直接呼び出す際の推奨値です。Orchestrator は Planner、Implementer、Reviewer を表の設定で起動し、指定モデルを利用できない場合は別モデルへ自動で切り替えず `BLOCKED` として報告します。

## 前提ツール

| 項目 | 要否 | 用途・条件 |
| --- | --- | --- |
| Codex | 必須 | Issue Agent Skills の実行 |
| Git | 必須 | 差分、branch、commit、push の管理 |
| GitHub CLI (`gh`) | Issue 実装フローで必須 | Issue・ラベルの操作と Draft PR 作成。事前に認証が必要 |
| Herdr | 任意 | Agent ごとの pane 分離。不在時は Codex サブエージェントを使用 |
| `HERDR_ENV=1` | Herdr 利用時のみ必須 | Herdr 管理 pane 内であることの判定 |

## 使い方

要件を整理して Issue を作成するときは `$issue-requirements-interviewer`、作成済みの1件の Issue を計画・実装・レビュー・Draft PR 作成まで進めるときは `$issue-orchestrator` を使用します。個別の Planner、Implementer、Reviewer は Orchestrator から呼び出す前提です。
