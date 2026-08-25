#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
script="$script_dir/scripts/public-state-comment.sh"
test_root=$(mktemp -d); trap 'rm -rf -- "$test_root"' EXIT
export TEST_COMMENT_STATE="$test_root/comments" TEST_GH_LOG="$test_root/gh.log"

fail() { printf 'not ok: %s\n' "$1" >&2; exit 1; }; pass() { printf 'ok: %s\n' "$1"; }

gh() {
  local method= url= body= arg id
  while (($#)); do
    case $1 in
      --method) method=$2; shift 2 ;; --paginate) shift ;;
      -f) arg=$2; body=${arg#body=}; shift 2 ;;
      *) url=$1; shift ;;
    esac
  done
  printf '%s %s\n' "$method" "$url" >>"$TEST_GH_LOG"
  [[ ${TEST_GH_FAIL:-} != "$method" ]] || return 1
  [[ -f $TEST_COMMENT_STATE ]] || printf '[]\n' >"$TEST_COMMENT_STATE"
  case $method in
    GET) cat "$TEST_COMMENT_STATE" ;;
    POST)
      id=$(jq 'map(.id) | max // 0 | . + 1' "$TEST_COMMENT_STATE")
      jq --argjson id "$id" --arg body "$body" '. + [{id:$id, body:$body}]' "$TEST_COMMENT_STATE" >"$TEST_COMMENT_STATE.new"
      mv "$TEST_COMMENT_STATE.new" "$TEST_COMMENT_STATE" ;;
    PATCH)
      id=${url##*/}
      jq --argjson id "$id" --arg body "$body" 'map(if .id == $id then .body = $body else . end)' "$TEST_COMMENT_STATE" >"$TEST_COMMENT_STATE.new"
      mv "$TEST_COMMENT_STATE.new" "$TEST_COMMENT_STATE"
      if [[ ${TEST_GH_DUPLICATE_AFTER_PATCH:-} == 1 ]]; then
        jq '. + [{id:999,body:"<!-- issue-agent-run-state:active:v1 --> duplicate"}]' "$TEST_COMMENT_STATE" >"$TEST_COMMENT_STATE.new"
        mv "$TEST_COMMENT_STATE.new" "$TEST_COMMENT_STATE"
      fi ;;
    *) return 2 ;;
  esac
}
export -f gh

common=(--repository owner/repo --issue-number 30 --run-id 0123456789abcdef0123456789abcdef --started-at 2026-08-25T00:00:00Z --updated-at 2026-08-25T00:01:00Z --current-state PLANNING --state-before-stop unset --resume-state unset --role Planner --model gpt-5.6-terra --outcome INITIALIZED --review-return-count 0 --test-summary 'not run' --branch unset --commit unset --draft-pr unset --head-sha unset --ci-summary unset --stop-or-wait-reason unset --opaque-checkpoint checkpoint-1 --safe-summary 'planning started' --redacted-integrity integrity-1)
run() { local op=$1; shift; bash "$script" "$op" "${common[@]}" "$@"; }
reset() { printf '[]\n' >"$TEST_COMMENT_STATE"; : >"$TEST_GH_LOG"; unset TEST_GH_FAIL TEST_GH_DUPLICATE_AFTER_PATCH; }

reset
run active-create >/dev/null || fail 'active create'
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 1 ]] || fail 'active create count'
jq -r '.[0].body' "$TEST_COMMENT_STATE" | grep -Fq '<!-- issue-agent-run-state:active:v1 -->' || fail 'active marker'
pass 'new active comment is created once'

run active-update --current-state IMPLEMENTING --updated-at 2026-08-25T00:02:00Z >/dev/null || fail 'active update'
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 1 ]] || fail 'active update count'
grep -Fq 'PATCH repos/owner/repo/issues/comments/1' "$TEST_GH_LOG" || fail 'active update PATCH'
pass 'existing active comment is updated in place'

reset
if run active-update >/dev/null 2>&1; then fail 'missing marker accepted'; fi
pass 'missing marker safely stops'

reset
printf '%s\n' '[{"id":1,"body":"<!-- issue-agent-run-state:active:v1 -->"},{"id":2,"body":"<!-- issue-agent-run-state:active:v1 -->"}]' >"$TEST_COMMENT_STATE"
if run active-update >/dev/null 2>&1; then fail 'duplicate marker accepted'; fi
pass 'duplicate markers safely stop'

reset; export TEST_GH_FAIL=POST
if run active-create >/dev/null 2>&1; then fail 'POST failure accepted'; fi
pass 'POST failure safely stops'

reset; export TEST_GH_FAIL=GET
if run active-create >/dev/null 2>&1; then fail 'active create GET failure accepted'; fi
! grep -qE '^(POST|PATCH) ' "$TEST_GH_LOG" || fail 'active create GET failure mutation'
pass 'active create GET failure has no mutation'

reset; run active-create >/dev/null; export TEST_GH_FAIL=PATCH
if run active-update >/dev/null 2>&1; then fail 'PATCH failure accepted'; fi
pass 'PATCH failure safely stops'

reset; run active-create >/dev/null; export TEST_GH_DUPLICATE_AFTER_PATCH=1
if run active-update >/dev/null 2>&1; then fail 'post-update duplicate accepted'; fi
pass 'post-update uniqueness is verified'

reset; run active-create >/dev/null
run checkpoint --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null || fail 'checkpoint'
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 2 ]] || fail 'checkpoint count'
! jq -r '.[1].body' "$TEST_COMMENT_STATE" | grep -Fq 'issue-agent-run-state:active:v1' || fail 'checkpoint has marker'
pass 'checkpoint is append-only and marker-free'

reset; run active-create >/dev/null
run switch --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --updated-at 2026-08-25T00:03:00Z --old-run-id 0123456789abcdef0123456789abcdef --old-opaque-checkpoint checkpoint-old --old-redacted-integrity integrity-old --old-state PLANNING --old-safe-summary 'old run summary' --old-transition 'PLANNING -> PLANNING' --discard-reason 'explicitly discarded' >/dev/null || fail 'switch'
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 2 ]] || fail 'switch count'
jq -r '.[1].body' "$TEST_COMMENT_STATE" | grep -Fq -- '- old_state: PLANNING' || fail 'switch old state checkpoint'
awk '/POST/{post=NR} /PATCH/{patch=NR} END { exit !(post < patch) }' "$TEST_GH_LOG" || fail 'switch order'
pass 'switch checkpoints old Run before updating the one active comment'

reset
if run active-create --safe-summary 'token ghp_abcdefghijklmnopqrstuvwxyz123456' >"$test_root/error" 2>&1; then fail 'secret accepted'; fi
! grep -Fq 'ghp_' "$test_root/error" || fail 'secret leaked by error'
pass 'unsafe public input is rejected without echoing it'

for credential in ghp_abcdefghijklmnopqrstuvwxyz123456 github_pat_abcdefghijklmnopqrstuvwxyz AKIAABCDEFGHIJKLMNOP; do
  reset
  if run active-create --safe-summary "$credential" >"$test_root/error" 2>&1; then fail "credential accepted: $credential"; fi
  ! grep -Fq "$credential" "$test_root/error" || fail 'credential leaked'
  ! grep -qE '^(POST|PATCH) ' "$TEST_GH_LOG" || fail 'credential mutation'
done
pass 'known credential forms are rejected before mutation'

reset; run active-create >/dev/null
if run active-update --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa >/dev/null 2>&1; then fail 'run mismatch accepted'; fi
! grep -q '^PATCH ' "$TEST_GH_LOG" || fail 'run mismatch PATCH'
pass 'active update requires the current Run ID'

reset
printf '%s\n' '[{"id":1,"body":"<!-- issue-agent-run-state:active:v1 -->\n## Issue Agent Run State (v1)\n- run_id: 0123456789abcdef0123456789abcdef"}]' >"$TEST_COMMENT_STATE"
if run active-update >/dev/null 2>&1; then fail 'malformed active schema accepted'; fi
! grep -q '^PATCH ' "$TEST_GH_LOG" || fail 'malformed schema PATCH'
pass 'active schema is verified before mutation'

reset
if run checkpoint --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null 2>&1; then fail 'checkpoint without active accepted'; fi
! grep -q '^POST ' "$TEST_GH_LOG" || fail 'missing active checkpoint POST'
pass 'checkpoint requires one active Run before POST'

reset; run active-create >/dev/null; : >"$TEST_GH_LOG"; export TEST_GH_FAIL=GET
if run checkpoint --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null 2>&1; then fail 'checkpoint GET failure accepted'; fi
! grep -q '^POST ' "$TEST_GH_LOG" || fail 'GET failure checkpoint POST'
pass 'checkpoint GET failure has no POST'

reset; run active-create >/dev/null; : >"$TEST_GH_LOG"; export TEST_GH_FAIL=POST
if run checkpoint --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null 2>&1; then fail 'checkpoint POST failure accepted'; fi
pass 'checkpoint POST failure safely stops'

reset; run active-create >/dev/null; : >"$TEST_GH_LOG"
if run checkpoint --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null 2>&1; then fail 'checkpoint run mismatch accepted'; fi
! grep -q '^POST ' "$TEST_GH_LOG" || fail 'checkpoint run mismatch POST'
pass 'checkpoint requires the current Run ID'

reset
printf '%s\n' '[{"id":1,"body":"<!-- issue-agent-run-state:active:v1 -->"},{"id":2,"body":"<!-- issue-agent-run-state:active:v1 -->"}]' >"$TEST_COMMENT_STATE"
if run checkpoint --event APPROVED --transition 'REVIEWING -> PUBLISHING' >/dev/null 2>&1; then fail 'checkpoint duplicate active accepted'; fi
! grep -q '^POST ' "$TEST_GH_LOG" || fail 'checkpoint duplicate POST'
pass 'checkpoint rejects duplicate active comments'

for event_args in \
  '--event BLOCKED --transition "IMPLEMENTING -> BLOCKED" --state-before-stop IMPLEMENTING --stop-or-wait-reason "external wait"' \
  '--event RESUMED --transition "BLOCKED -> IMPLEMENTING" --resume-state IMPLEMENTING' \
  '--event PUBLISHED --transition "PUBLISHING -> COMPLETED"'; do
  reset; run active-create >/dev/null
  eval "run checkpoint $event_args" >/dev/null || fail "checkpoint event $event_args"
done
pass 'BLOCKED RESUMED and PUBLISHED checkpoints are accepted'

reset; run active-create --token-count 123 --cost 1.25 >/dev/null || fail 'optional metrics'
jq -r '.[0].body' "$TEST_COMMENT_STATE" | grep -Fq -- '- token_count: 123' || fail 'token metric'
pass 'optional metrics are included only when supplied'

for unsafe in $'tab\tvalue' '/var/lib/private/run.json' "$(printf 'a%.0s' {1..161})" 'manifest changed file list' 'Authorization Bearer mystery'; do
  reset
  if run active-create --safe-summary "$unsafe" >"$test_root/error" 2>&1; then fail "unsafe input accepted: $unsafe"; fi
  ! grep -Fq "$unsafe" "$test_root/error" || fail 'unsafe input leaked'
done
pass 'control characters paths long text and log-like inputs are rejected'

reset; run active-create >/dev/null; : >"$TEST_GH_LOG"
if run switch --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --old-run-id 0123456789abcdef0123456789abcdef --old-opaque-checkpoint checkpoint-old --old-redacted-integrity integrity-old --old-state PLANNING --old-safe-summary 'old run summary' --old-transition 'PLANNING -> PLANNING' --discard-reason 'explicitly discarded' --safe-summary $'bad\tvalue' >/dev/null 2>&1; then fail 'invalid switch accepted'; fi
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 1 ]] || fail 'invalid switch wrote checkpoint'
! grep -qE '^(POST|PATCH) ' "$TEST_GH_LOG" || fail 'invalid switch API mutation'
pass 'switch validates every body before mutation'

reset; run active-create >/dev/null; : >"$TEST_GH_LOG"
if run switch --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --old-run-id bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb --old-opaque-checkpoint checkpoint-old --old-redacted-integrity integrity-old --old-state PLANNING --old-safe-summary 'old run summary' --old-transition 'PLANNING -> PLANNING' --discard-reason 'explicitly discarded' >/dev/null 2>&1; then fail 'switch old Run mismatch accepted'; fi
! grep -qE '^(POST|PATCH) ' "$TEST_GH_LOG" || fail 'switch mismatch API mutation'
pass 'switch requires the existing old Run ID'

reset; run active-create >/dev/null; export TEST_GH_FAIL=PATCH
if run switch --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --old-run-id 0123456789abcdef0123456789abcdef --old-opaque-checkpoint checkpoint-old --old-redacted-integrity integrity-old --old-state PLANNING --old-safe-summary 'old run summary' --old-transition 'PLANNING -> PLANNING' --discard-reason 'explicitly discarded' >/dev/null 2>&1; then fail 'switch PATCH failure accepted'; fi
[[ $(jq 'length' "$TEST_COMMENT_STATE") == 2 ]] || fail 'switch checkpoint missing before PATCH failure'
pass 'switch PATCH failure stops after the audit checkpoint'

reset; run active-create >/dev/null; export TEST_GH_DUPLICATE_AFTER_PATCH=1
if run switch --run-id aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa --old-run-id 0123456789abcdef0123456789abcdef --old-opaque-checkpoint checkpoint-old --old-redacted-integrity integrity-old --old-state PLANNING --old-safe-summary 'old run summary' --old-transition 'PLANNING -> PLANNING' --discard-reason 'explicitly discarded' >/dev/null 2>&1; then fail 'switch post-PATCH duplicate accepted'; fi
pass 'switch verifies uniqueness after PATCH'
