#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
initializer="$script_dir/scripts/initialize-run.sh"
test_root=$(mktemp -d)
trap 'rm -rf -- "$test_root"' EXIT

fail() { printf 'not ok: %s\n' "$1" >&2; exit 1; }
pass() { printf 'ok: %s\n' "$1"; }
run_ok() { ISSUE_AGENT_STATE_DIR="$1" "$initializer" 29 --run-id "$2"; }
run_blocked() {
  local root=$1 run=$2
  if ISSUE_AGENT_STATE_DIR="$root" "$initializer" 29 --run-id "$run" >/dev/null 2>&1; then
    fail "expected safe stop for $root"
  fi
}

repo="$test_root/repository"
git init -q "$repo"
git -C "$repo" remote add origin 'https://token:p@ss@example.test/group/project.git/'
cd "$repo"

root="$test_root/state"
mkdir -m 700 "$root"
result=$(run_ok "$root" '0123456789abcdef0123456789abcdef') || fail 'normal initialization'
repository_id=$(printf '%s' "$result" | sed -n 's/.*"repository_id":"\([a-f0-9]*\)".*/\1/p')
expected_id=$(printf '%s' 'https://example.test/group/project' | sha256sum | awk '{print $1}')
[[ $repository_id == "$expected_id" ]] || fail 'URL normalisation'
state="$root/$repository_id/29/0123456789abcdef0123456789abcdef/run.json"
[[ $(stat -c '%a' "$root/$repository_id/29/0123456789abcdef0123456789abcdef") == 700 ]] || fail 'Run mode'
[[ $(stat -c '%a' "$state") == 600 ]] || fail 'state file mode'
grep -Fq '"state":"PLANNING"' "$state" || fail 'initial state'
pass 'normal initialization and URL normalisation'

git -C "$repo" remote set-url origin 'https://example.test/group/project@variant.git'
variant_root="$test_root/variant-state"
mkdir -m 700 "$variant_root"
variant_result=$(run_ok "$variant_root" 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb') || fail 'path @ initialization'
variant_id=$(printf '%s' "$variant_result" | sed -n 's/.*"repository_id":"\([a-f0-9]*\)".*/\1/p')
expected_variant_id=$(printf '%s' 'https://example.test/group/project@variant' | sha256sum | awk '{print $1}')
[[ $variant_id == "$expected_variant_id" ]] || fail 'path @ URL normalisation'
pass 'path @ is retained in URL normalisation'
git -C "$repo" remote set-url origin 'https://token:p@ss@example.test/group/project.git/'

default_home="$test_root/default-home"
result=$(env -u ISSUE_AGENT_STATE_DIR -u XDG_STATE_HOME HOME="$default_home" "$initializer" 29 --run-id 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') || fail 'default root initialization'
[[ -f "$default_home/.local/state/issue-agent-runs/$repository_id/29/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/run.json" ]] || fail 'default root location'
pass 'default root initialization'

run_blocked "$root" '0123456789abcdef0123456789abcdef'
pass 'existing Run is rejected'

late_failure=$(ISSUE_AGENT_STATE_DIR="$root" "$initializer" 29 --run-id '0123456789abcdef0123456789abcdef' 2>&1) && fail 'existing Run unexpectedly succeeded'
grep -Fq '"outcome":"BLOCKED"' <<<"$late_failure" || fail 'late failure outcome'
grep -Fq '"issue_number":29' <<<"$late_failure" || fail 'late failure issue number'
grep -Fq '"run_id":"0123456789abcdef0123456789abcdef"' <<<"$late_failure" || fail 'late failure run ID'
grep -Fq "\"repository_id\":\"$repository_id\"" <<<"$late_failure" || fail 'late failure repository ID'
grep -Fq '"state":null' <<<"$late_failure" || fail 'late failure state is null'
[[ $late_failure != *"$root"* && $late_failure != *'File exists'* ]] || fail 'late failure leaked private diagnostics'
pass 'late failure returns safe machine-readable identifiers'

diagnostic_root="$test_root/diagnostic-root"
mkdir -m 700 "$diagnostic_root"
stat() {
  printf 'stat: cannot inspect %s: Permission denied\n' "${!#}" >&2
  return 1
}
export -f stat
diagnostic_output=$(ISSUE_AGENT_STATE_DIR="$diagnostic_root" "$initializer" 29 --run-id 'cccccccccccccccccccccccccccccccc' 2>&1) && fail 'diagnostic failure unexpectedly succeeded'
unset -f stat
grep -Fq '"outcome":"BLOCKED"' <<<"$diagnostic_output" || fail 'diagnostic failure outcome'
[[ $diagnostic_output != *"$diagnostic_root"* && $diagnostic_output != *'Permission denied'* ]] || fail 'diagnostic failure leaked private diagnostics'
pass 'inspection failure returns only a safe summary'

od() {
  printf 'od: cannot read /private/random-source: Input/output error\n' >&2
  return 1
}
export -f od
run_id_failure=$(ISSUE_AGENT_STATE_DIR="$test_root/not-used" "$initializer" 29 2>&1) && fail 'run ID generation failure unexpectedly succeeded'
unset -f od
grep -Fq '"outcome":"BLOCKED"' <<<"$run_id_failure" || fail 'run ID failure outcome'
grep -Fq '"run_id":null' <<<"$run_id_failure" || fail 'run ID failure is null'
[[ $run_id_failure != *'/private/random-source'* && $run_id_failure != *'Input/output error'* ]] || fail 'run ID failure leaked diagnostics'
pass 'run ID generation failure returns only a safe summary'

unsafe_mode="$test_root/unsafe-mode"
mkdir -m 755 "$unsafe_mode"
run_blocked "$unsafe_mode" '11111111111111111111111111111111'
pass 'unsafe mode is rejected'

symlink_root="$test_root/symlink-root"
ln -s "$root" "$symlink_root"
run_blocked "$symlink_root" '22222222222222222222222222222222'
run_blocked "$symlink_root/" '22222222222222222222222222222222'
pass 'symlink root including trailing separator is rejected'

readonly_parent="$test_root/readonly-parent"
mkdir -m 700 "$readonly_parent"
readonly_root="$readonly_parent/root"
mkdir -m 700 "$readonly_root"
repository_path="$readonly_root/$repository_id"
mkdir -m 700 "$repository_path"
chmod 500 "$repository_path"
if [[ $(id -u) != 0 ]]; then
  run_blocked "$readonly_root" '33333333333333333333333333333333'
  pass 'uncreatable directory is rejected'
else
  printf 'ok: uncreatable directory check skipped for root user\n'
fi

foreign_root="$test_root/foreign-root"
mkdir -m 700 "$foreign_root"
if [[ $(id -u) == 0 ]] && command -v chown >/dev/null; then
  chown 65534 "$foreign_root"
  run_blocked "$foreign_root" '44444444444444444444444444444444'
else
  # Simulate stat's ownership observation when the test user cannot create a
  # directory owned by somebody else.  The production helper still performs the
  # real stat(1) check; this only covers its rejection branch.
  stat() {
    if [[ ${1:-} == -c && ${2:-} == %u ]]; then
      printf '%s\n' "$(( $(id -u) + 1 ))"
    else
      /usr/bin/stat "$@"
    fi
  }
  export -f stat
  run_blocked "$foreign_root" '44444444444444444444444444444444'
  unset -f stat
fi
pass 'foreign owner is rejected'

outside_root="$test_root/outside-root"
mkdir -m 700 "$outside_root"
export ISSUE_AGENT_TEST_RUN_ID='55555555555555555555555555555555'
realpath() {
  if [[ ${!#} == *"/$ISSUE_AGENT_TEST_RUN_ID" ]]; then
    printf '%s\n' '/outside-the-state-root'
  else
    /usr/bin/realpath "$@"
  fi
}
export -f realpath
run_blocked "$outside_root" "$ISSUE_AGENT_TEST_RUN_ID"
unset -f realpath
unset ISSUE_AGENT_TEST_RUN_ID
pass 'resolved path outside the root is rejected'
