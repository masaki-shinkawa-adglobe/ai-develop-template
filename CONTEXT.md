# Issue Agent Skills

1件のGitHub Issueを、役割分離されたAgentと観測可能な状態遷移によって完了まで進める文脈である。

## Language

**Run**:
1件のIssueを計画開始から完了まで進める実行単位。停止と再開をまたいで同じ同一性を保ち、以前の状態を破棄して最初からやり直す場合だけ新しくなる。
_Avoid_: Session, Attempt

**BLOCKED**:
人の判断、権限、外部状態変更、または範囲外対応を待つ、再開可能なRunの停止状態。現在のOrchestrator実行は終了するが、Run自体は終了しない。
_Avoid_: Failed, Cancelled, Completed

**再開状態**:
停止したRunで次に着手すべき未完了の状態。停止を検知した状態とは異なる場合がある。
_Avoid_: Restart State, `blocked_from`

**Reconciliation Manifest**:
再開前の照合で、由来と範囲を安全に説明できた外部変更の一覧。Implementerが作成した変更の一覧とは分離して扱う。
_Avoid_: Implementer Manifest, Untracked Changes

**Conflict Resolver**:
Gitが生成した競合について変更の意図を調査し、両立可能な競合だけを解消する専門役。予防的なPR比較、Issueの実装、解消結果の承認は担当しない。
_Avoid_: Implementer, Reviewer

**Conflict Resolution Manifest**:
Conflict Resolverが競合解消のために変更した範囲と、その根拠となる競合意図の一覧。Implementerの変更および第三者による外部変更とは分離して扱う。
_Avoid_: Implementer Manifest, Reconciliation Manifest
