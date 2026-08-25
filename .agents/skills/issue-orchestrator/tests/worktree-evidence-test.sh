#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
initializer="$script_dir/scripts/initialize-run.sh"
evidence="$script_dir/scripts/worktree-evidence.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT
fail() { printf 'not ok: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }

repo="$test_root/repo"
git init -q "$repo"
git -C "$repo" config user.email test@example.test
git -C "$repo" config user.name test
git -C "$repo" remote add origin https://example.test/owner/repo.git
printf 'base\n' >"$repo/tracked.txt"
git -C "$repo" add tracked.txt && git -C "$repo" commit -qm base
state="$test_root/state"; mkdir -m 700 "$state"
result=$(cd "$repo" && ISSUE_AGENT_STATE_DIR="$state" "$initializer" 31 --run-id 0123456789abcdef0123456789abcdef) || fail 'run initialization'
repository_id=$(sed -n 's/.*"repository_id":"\([a-f0-9]*\)".*/\1/p' <<<"$result")
run_dir="$state/$repository_id/31/0123456789abcdef0123456789abcdef"
cd "$repo"

call_id=$(bash "$evidence" new-call-id --run-dir "$run_dir") || fail 'call ID generation'
[[ $call_id =~ ^[a-f0-9]{64}$ ]] || fail 'call ID format'
pass 'cryptographic Role call ID is issued'

bash "$evidence" capture --run-dir "$run_dir" --name planner-before >/dev/null
bash "$evidence" capture --run-dir "$run_dir" --name planner-after >/dev/null
bash "$evidence" record-role --run-dir "$run_dir" --call-id planner-1 --role Planner --before planner-before --after planner-after --outcome PLANNED --origin none >/dev/null
[[ -f "$run_dir/role-calls/planner-1/origin" && $(cat "$run_dir/role-calls/planner-1/origin") == none ]] || fail 'Planner evidence was not saved'
pass 'non-changing Planner Role evidence is separate from manifests'

bash "$evidence" capture --run-dir "$run_dir" --name before >/dev/null
printf 'staged\n' >tracked.txt; git add tracked.txt
printf 'worktree\n' >tracked.txt
printf 'untracked\n' >untracked.txt
bash "$evidence" capture --run-dir "$run_dir" --name after >/dev/null
entries="$run_dir/fingerprints/after/entries.tsv"
[[ $(wc -l <"$entries") == 2 ]] || fail 'tracked and untracked identities captured'
grep -Fq $'100644\t' "$entries" || fail 'index mode captured'
grep -Fq $'present' "$entries" || fail 'existence state captured'
grep -Fq '?? untracked.txt' <(tr '\0' '\n' <"$run_dir/fingerprints/after/status.porcelain") || fail 'full porcelain status captured'
pass 'tracked, staged, worktree, and untracked identities are captured privately'

printf 'tracked.txt\nuntracked.txt\n' >"$test_root/manifest"
bash "$evidence" record-role --run-dir "$run_dir" --call-id implement-1 --role Implementer --before before --after after --outcome IMPLEMENTED --manifest "$test_root/manifest" --origin implementer >/dev/null
[[ -f "$run_dir/role-calls/implement-1/outcome" && -f "$run_dir/manifests/implementer.b64" ]] || fail 'Role evidence was not saved'
pass 'matching Role boundary and complete manifest are promoted'

bash "$evidence" capture --run-dir "$run_dir" --name before-mode >/dev/null
chmod +x tracked.txt
bash "$evidence" capture --run-dir "$run_dir" --name after-mode >/dev/null
grep -Fq $'100755\t' "$run_dir/fingerprints/after-mode/entries.tsv" || fail 'worktree executable mode captured'
pass 'worktree executable bit uses filesystem Git-compatible mode'

# A conflicted path has no stage 0.  Changing just stage 2 or just stage 3
# must alter the stored identity and cannot pass through a non-changing Role.
git update-index --force-remove tracked.txt
base_blob=$(git rev-parse HEAD:tracked.txt)
left_one=$(printf 'left one\n' | git hash-object -w --stdin)
right_one=$(printf 'right one\n' | git hash-object -w --stdin)
printf '100644 %s 1\ttracked.txt\n100644 %s 2\ttracked.txt\n100644 %s 3\ttracked.txt\n' "$base_blob" "$left_one" "$right_one" | git update-index --index-info
bash "$evidence" capture --run-dir "$run_dir" --name conflict-before >/dev/null
left_two=$(printf 'left two\n' | git hash-object -w --stdin)
printf '100644 %s 2\ttracked.txt\n' "$left_two" | git update-index --index-info
bash "$evidence" capture --run-dir "$run_dir" --name conflict-stage-2 >/dev/null
grep -Fq "2:$left_two" "$run_dir/fingerprints/conflict-stage-2/entries.tsv" || fail 'stage 2 blob captured'
[[ $(cat "$run_dir/fingerprints/conflict-before/digest") != $(cat "$run_dir/fingerprints/conflict-stage-2/digest") ]] || fail 'stage 2 change did not alter digest'
if bash "$evidence" record-role --run-dir "$run_dir" --call-id conflict-stage-2 --role Reviewer --before conflict-before --after conflict-stage-2 --outcome APPROVED --origin none >/dev/null 2>"$test_root/conflict-stage-2-error"; then fail 'stage 2 change passed non-changing Role'; fi
grep -Fq 'non-changing Role has worktree changes' "$test_root/conflict-stage-2-error" || fail 'stage 2 change was not rejected'
right_two=$(printf 'right two\n' | git hash-object -w --stdin)
printf '100644 %s 3\ttracked.txt\n' "$right_two" | git update-index --index-info
bash "$evidence" capture --run-dir "$run_dir" --name conflict-stage-3 >/dev/null
grep -Fq "3:$right_two" "$run_dir/fingerprints/conflict-stage-3/entries.tsv" || fail 'stage 3 blob captured'
[[ $(cat "$run_dir/fingerprints/conflict-stage-2/digest") != $(cat "$run_dir/fingerprints/conflict-stage-3/digest") ]] || fail 'stage 3 change did not alter digest'
if bash "$evidence" record-role --run-dir "$run_dir" --call-id conflict-stage-3 --role Reviewer --before conflict-stage-2 --after conflict-stage-3 --outcome APPROVED --origin none >/dev/null 2>"$test_root/conflict-stage-3-error"; then fail 'stage 3 change passed non-changing Role'; fi
grep -Fq 'non-changing Role has worktree changes' "$test_root/conflict-stage-3-error" || fail 'stage 3 change was not rejected'
pass 'all conflicted index stages affect fingerprints and Role boundaries'

bash "$evidence" capture --run-dir "$run_dir" --name before-delete >/dev/null
rm tracked.txt
bash "$evidence" capture --run-dir "$run_dir" --name after-delete >/dev/null
grep -Fq $'absent\tabsent\tdeleted' "$run_dir/fingerprints/after-delete/entries.tsv" || fail 'deleted worktree identity captured'
printf 'untracked.txt\n' >"$test_root/bad-manifest"
if bash "$evidence" record-role --run-dir "$run_dir" --call-id implement-2 --role Implementer --before before-delete --after after-delete --outcome IMPLEMENTED --manifest "$test_root/bad-manifest" --origin implementer >/dev/null 2>"$test_root/error"; then fail 'manifest mismatch accepted'; fi
grep -Fq 'manifest does not match Role boundary identities' "$test_root/error" || fail 'mismatch did not stop safely'
[[ $(cat "$test_root/error") != *tracked.txt* ]] || fail 'mismatch leaked changed path'
pass 'deleted and manifest-external identity changes are rejected without path disclosure'

bash "$evidence" capture --run-dir "$run_dir" --name reviewer-before >/dev/null
bash "$evidence" capture --run-dir "$run_dir" --name reviewer-after >/dev/null
bash "$evidence" record-role --run-dir "$run_dir" --call-id reviewer-1 --role Reviewer --before reviewer-before --after reviewer-after --outcome APPROVED --origin none >/dev/null
[[ -f "$run_dir/role-calls/reviewer-1/outcome" ]] || fail 'Reviewer evidence was not saved'
pass 'Planner, Implementer, and Reviewer evidence is recorded in sequence'

bash "$evidence" capture --run-dir "$run_dir" --name reviewed >/dev/null
published=$(bash "$evidence" assert-publish --run-dir "$run_dir" --expected reviewed) || fail 'unchanged publish fingerprint'
[[ -d $published ]] || fail 'unchanged publish fingerprint was not saved'
pass 'unchanged publish fingerprint matches regardless of snapshot name'
printf 'parallel change\n' >untracked.txt
if bash "$evidence" assert-publish --run-dir "$run_dir" --expected reviewed >/dev/null 2>"$test_root/publish-error"; then fail 'publish mismatch accepted'; fi
grep -Fq 'worktree differs from reviewed fingerprint' "$test_root/publish-error" || fail 'publish mismatch was not detected'
[[ $(cat "$test_root/publish-error") != *untracked.txt* ]] || fail 'publish mismatch leaked path'
pass 'publish requires the reviewed fingerprint and keeps output safe'

unsafe="$test_root/unsafe"; cp -a "$run_dir" "$unsafe"; chmod 755 "$unsafe"
if bash "$evidence" capture --run-dir "$unsafe" --name no >/dev/null 2>&1; then fail 'unsafe Run directory accepted'; fi
pass 'unsafe Run directory is rejected'
