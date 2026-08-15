---
name: issue-agent-bootstrap
description: Diagnose, initialize, and safely verify the environment for Issue Agent Skills. Use when introducing Issue Agent Skills to a repository, investigating a stopped Issue Orchestrator, checking Codex, Git, GitHub CLI, authentication, permissions, labels, or Herdr, preparing the agreed labels, or explicitly requesting a live end-to-end verification.
---

# Issue Agent Bootstrap

Use this skill in the order `doctor` → `initialize` → re-diagnose → `verify` when needed. Do not install or update Codex, Git, GitHub CLI, or Herdr. Never repair global configuration or permission settings: diagnose, stop, and suggest a safe next action instead.

Start the first non-empty response line with exactly one of:

```text
OUTCOME: READY
OUTCOME: INITIALIZED
OUTCOME: VERIFIED
OUTCOME: BLOCKED
```

Report warnings, checks, changes, run-ID resources, cleanup results, and remaining work in Markdown after that line. Use `WARNING` for Herdr-only failures. Use `BLOCKED` for a failed required check, a global configuration or permission diagnostic error, or missing approval for a requested mutation.

## doctor

Keep `doctor` read-only. Identify the repository root and worktree, then record the commands and concise results for:

1. Codex CLI (`command -v codex`, `codex --version`), Git (`git --version`), and GitHub CLI (`gh --version`).
2. GitHub authentication without exposing tokens (`gh auth status`), the target repository, and the effective repository permission (`gh repo view` or `gh api repos/{owner}/{repo}` and its viewer permission). Before recording or reporting remote output, remove or mask credentials, URL userinfo, API keys, and tokens; never expose secrets. Require permission sufficient for the intended Issue, label, branch, push, and Draft PR operations.
3. Repository and worktree state (`git rev-parse --show-toplevel`, `git status --porcelain=v1 -uall`, branch, remotes, and whether the worktree is usable). Treat an unexpected dirty worktree as a diagnostic finding; do not overwrite it.
4. The seven required labels by listing labels read-only and comparing exact name, color, and description against the table below.
5. Herdr: `HERDR_ENV=1`, `command -v herdr`, `herdr --help`, `herdr agent --help`, and `herdr pane --help`. Check all five conditions. If any Herdr condition fails, report `WARNING` and state that `$issue-orchestrator` will use Codex subagents; do not block solely for Herdr.

Treat Codex, Git, `gh`, GitHub authentication, repository access, effective required permission, usable repository/worktree, and all seven labels as required. If any required check fails, return `OUTCOME: BLOCKED` with the failed check and safe next action. If a global configuration or permission diagnostic produces an error, stop read-only, report the error without secrets, and never repair it; suggest a safe next action. Return `OUTCOME: READY` only when required checks pass; retain Herdr warnings in the report.

## initialize

First run `doctor` and show a preview containing only missing or differing labels. Do not mutate anything until the user explicitly asks to execute the displayed initialization.

On that explicit execution request, converge only the labels in this table. Create a missing label; update an existing label only if its color or description differs; leave every other label unchanged. Use GitHub CLI or its API idempotently, then run `doctor` again. Return `OUTCOME: INITIALIZED` only if the re-diagnosis matches the table. Otherwise return `OUTCOME: BLOCKED` with the remaining difference.

| Label | Color | Description |
| --- | --- | --- |
| `status:in-progress` | `1D76DB` | `Planner、Implementer、Conflict Resolver、レビュー指摘の修正中` |
| `status:review` | `FBCA04` | `Reviewer実行中、Reviewer承認後、Draft PR作成後` |
| `status:blocked` | `D73A4A` | `作業を続行できないblockerあり` |
| `priority:critical` | `B60205` | `サービス停止、重大なセキュリティ問題、またはデータ損失` |
| `priority:high` | `D93F0B` | `高い優先度で対応が必要` |
| `priority:medium` | `FBCA04` | `通常の優先度` |
| `priority:low` | `0E8A16` | `低い優先度` |

Never use Bootstrap to modify global configuration or permissions, including after explicit user approval. A global configuration or permission diagnostic error remains `BLOCKED`; report it and suggest a safe next action.

## verify

Keep normal `verify` read-only: re-run `doctor`, inspect the Skill files and the Orchestrator contract, run the skill validator and `git diff --check`, and report `OUTCOME: READY` when the environment and static checks pass. Never create GitHub resources in normal verification.

Perform live verification only when the user explicitly requests it and explicitly approves all of the following before any write:

- A unique run ID and the exact test Issue, branch, and Draft PR resources that may be created.
- GitHub writes, including label transitions and the orchestrated commit and push.
- The cleanup policy for both success and failure. Preserve failure evidence by default; delete only resources explicitly approved for cleanup.

After approval, create resources whose titles, branch, and report include the run ID. Invoke `$issue-orchestrator` for the test Issue. Validate the Planner, Implementer, and Reviewer outcomes; the required `status:*` label transitions; the three manifest categories; the reviewed commit and push; and the Draft PR's draft state, base, head, and body. Confirm that the test Issue has exactly one state comment containing `<!-- issue-agent-run-state:active:v1 -->`, that it records the approved run ID and final `COMPLETED` state, and that a separate marker-free completion checkpoint exists. Confirm that the Draft PR head SHA matches the recorded CI target SHA and that either every required check for that SHA succeeded or the state comment explicitly records that no required CI is configured. Validate the Conflict Resolver outcome only when the explicitly approved live scenario actually creates a merge conflict. Never merge merely to add conflict coverage to a live verification that did not approve it.

Report the Issue URL, PR URL, branch, every inspected result, cleanup actions, and retained failure evidence. Clean up only approved run-ID resources and never touch unrelated resources. Return `OUTCOME: VERIFIED` only after every approved check succeeds; otherwise return `OUTCOME: BLOCKED` with evidence and remaining resources.
