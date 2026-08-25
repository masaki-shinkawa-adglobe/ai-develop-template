#!/usr/bin/env bash
# Private worktree fingerprints and Role-change attribution for Issue Agent Runs.
set -euo pipefail

blocked() { printf '%s\n' "BLOCKED: $1" >&2; exit 1; }
usage() { printf '%s\n' 'usage: worktree-evidence.sh {capture|new-call-id|record-role|assert-publish} OPTIONS' >&2; exit 2; }

run_dir= call_id= role= before= after= outcome= manifest= origin= name= expected=
while (($#)); do
  case $1 in
    capture|new-call-id|record-role|assert-publish) command=${command:-$1}; shift;;
    --run-dir) run_dir=${2:-}; shift 2;; --name) name=${2:-}; shift 2;;
    --call-id) call_id=${2:-}; shift 2;; --role) role=${2:-}; shift 2;;
    --before) before=${2:-}; shift 2;; --after) after=${2:-}; shift 2;;
    --outcome) outcome=${2:-}; shift 2;; --manifest) manifest=${2:-}; shift 2;;
    --origin) origin=${2:-}; shift 2;; --expected) expected=${2:-}; shift 2;;
    *) usage;;
  esac
done
[[ ${command:-} ]] || usage

[[ $run_dir = /* && ! -L $run_dir && -d $run_dir ]] || blocked 'unsafe Run directory'
uid=$(id -u)
[[ $(stat -c '%u' -- "$run_dir") == "$uid" && $(stat -c '%a' -- "$run_dir") == 700 ]] || blocked 'unsafe Run directory'
resolved_run=$(realpath -e -- "$run_dir") || blocked 'unsafe Run directory'
[[ $resolved_run == "$run_dir" ]] || blocked 'unsafe Run directory'
[[ -f "$run_dir/run.json" && ! -L "$run_dir/run.json" && $(stat -c '%a' -- "$run_dir/run.json") == 600 ]] || blocked 'unsafe Run directory'

safe_name() { [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]]; }
private_dir() { local d=$1; mkdir -m 700 -- "$d" 2>/dev/null || [[ -d $d && ! -L $d && $(stat -c '%a' -- "$d") == 700 ]]; }
private_file() { [[ ! -e $1 && ! -L $1 ]]; }

fingerprints="$run_dir/fingerprints"
calls="$run_dir/role-calls"
manifests="$run_dir/manifests"
for d in "$fingerprints" "$calls" "$manifests"; do private_dir "$d" || blocked 'private evidence storage could not be secured'; done

b64() { base64 -w0; }
entry_for_path() {
  local path=$1 index_lines index_mode index_blob index_state work_mode work_blob
  index_lines=$(git ls-files -s -- "$path")
  if [[ -n $index_lines ]]; then
    # An unmerged path has stages 1, 2 and 3.  Keep each stage's identity,
    # rather than silently using the first (usually stage 1) line.
    index_mode=$(awk '{print $3 ":" $1}' <<<"$index_lines" | LC_ALL=C sort -t: -k1,1n | paste -sd, -)
    index_blob=$(awk '{print $3 ":" $2}' <<<"$index_lines" | LC_ALL=C sort -t: -k1,1n | paste -sd, -)
    index_state=$(awk '{print $3 ":present"}' <<<"$index_lines" | LC_ALL=C sort -t: -k1,1n | paste -sd, -)
  else
    index_mode=absent; index_blob=absent; index_state=absent
  fi
  if [[ -e $path || -L $path ]]; then
    # Git tracks regular files as 100644/100755 irrespective of the other
    # filesystem permission bits; derive that mode from the worktree itself.
    if [[ -L $path ]]; then work_mode=120000
    elif [[ -f $path && -x $path ]]; then work_mode=100755
    elif [[ -f $path ]]; then work_mode=100644
    else work_mode=$(stat -c '%f' -- "$path")
    fi
    work_blob=$(git hash-object --no-filters -- "$path" 2>/dev/null) || work_blob=unhashable
    work_state=present
  else
    work_mode=absent; work_blob=absent; work_state=deleted
  fi
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$(printf '%s' "$path" | b64)" "$index_mode" "$index_blob" "$index_state" "$work_mode" "$work_blob" "$work_state"
}
capture() {
  safe_name "$name" || blocked 'unsafe fingerprint name'
  local target="$fingerprints/$name"
  private_file "$target" || blocked 'fingerprint already exists'
  (umask 077; mkdir "$target") || blocked 'fingerprint could not be saved'
  chmod 700 "$target"
  git rev-parse HEAD >"$target/head" 2>/dev/null || blocked 'HEAD could not be captured'
  git status --porcelain=v1 -uall -z >"$target/status.porcelain" || blocked 'status could not be captured'
  : >"$target/entries.tsv"
  declare -A seen=()
  while IFS= read -r -d '' path; do
    [[ $path != *$'\n'* ]] || blocked 'newline path cannot be represented safely'
    [[ ${seen[$path]+x} ]] && continue; seen[$path]=1; entry_for_path "$path" >>"$target/entries.tsv"
  done < <({ git diff --name-only --no-renames -z HEAD; git ls-files --others --exclude-standard -z; })
  sort -o "$target/entries.tsv" "$target/entries.tsv"
  # Hash canonical labelled bytes, not sha256sum's filename-bearing output.
  { printf 'head\0'; cat "$target/head"; printf '\0status\0'; cat "$target/status.porcelain"; printf '\0entries\0'; cat "$target/entries.tsv"; } | sha256sum | awk '{print $1}' >"$target/digest"
  chmod 600 "$target"/*
  printf '%s\n' "$target"
}
new_call_id() {
  local generated
  generated=$({ od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; } 2>/dev/null) || blocked 'call ID could not be generated'
  [[ $generated =~ ^[a-f0-9]{64}$ && ! -e "$calls/$generated" && ! -L "$calls/$generated" ]] || blocked 'call ID could not be generated'
  printf '%s\n' "$generated"
}
manifest_b64() {
  [[ -f $manifest && ! -L $manifest ]] || blocked 'manifest is not a regular file'
  : >"$1"
  while IFS= read -r path || [[ -n $path ]]; do
    [[ $path && $path != /* && $path != *'..'* && $path != *$'\t'* && $path != *$'\n'* ]] || blocked 'manifest has an unsafe path'
    printf '%s\n' "$(printf '%s' "$path" | b64)" >>"$1"
  done <"$manifest"
  sort -u -o "$1" "$1"
}
changed_paths() {
  local old=$1 new=$2 output=$3
  [[ -f "$old/entries.tsv" && -f "$new/entries.tsv" ]] || blocked 'fingerprint is incomplete'
  awk -F '\t' 'FNR == NR { old[$1] = $0; next } { fresh[$1] = $0 } END { for (path in old) if (!(path in fresh) || old[path] != fresh[path]) print path; for (path in fresh) if (!(path in old)) print path }' "$old/entries.tsv" "$new/entries.tsv" | sort -u >"$output"
  [[ $(cat "$old/head") == $(cat "$new/head") ]] || blocked 'HEAD changed across Role boundary'
}
record_role() {
  safe_name "$call_id" && safe_name "$before" && safe_name "$after" || blocked 'unsafe role evidence identifier'
  [[ $role =~ ^[A-Za-z][A-Za-z_-]{1,63}$ && $outcome =~ ^[A-Z][A-Z_]{1,63}$ ]] || blocked 'unsafe Role evidence'
  [[ $origin == none || $origin == implementer || $origin == conflict-resolution || $origin == reconciliation ]] || blocked 'unsafe manifest origin'
  local before_dir="$fingerprints/$before" after_dir="$fingerprints/$after" call_dir="$calls/$call_id" actual declared
  actual="$call_dir/actual.b64"; declared="$call_dir/declared.b64"
  [[ -d $before_dir && -d $after_dir && ! -e $call_dir && ! -L $call_dir ]] || blocked 'Role evidence cannot be recorded'
  (umask 077; mkdir "$call_dir") || blocked 'Role evidence cannot be recorded'; chmod 700 "$call_dir"
  changed_paths "$before_dir" "$after_dir" "$actual"
  if [[ $origin == none ]]; then
    [[ ! -s $actual && -z $manifest ]] || blocked 'non-changing Role has worktree changes'
    : >"$declared"; : >"$call_dir/manifest"
  else
    manifest_b64 "$declared"
    cp -- "$manifest" "$call_dir/manifest"
  fi
  printf '%s\n' "$role" >"$call_dir/role"; printf '%s\n' "$outcome" >"$call_dir/outcome"; printf '%s\n' "$before" >"$call_dir/before"; printf '%s\n' "$after" >"$call_dir/after"; printf '%s\n' "$origin" >"$call_dir/origin"
  chmod 600 "$call_dir"/*
  [[ $origin == none ]] && { printf '%s\n' "$call_dir"; return; }
  local cumulative="$manifests/$origin.b64" temp
  temp="$call_dir/cumulative.b64"
  touch "$cumulative"; chmod 600 "$cumulative"
  # A Role returns its complete origin manifest.  The new boundary delta must be
  # contained in it, and the full declaration must be exactly the prior
  # cumulative manifest plus that delta; neither omitted prior paths nor a
  # manifest-only path can be silently attributed.
  { cat "$cumulative"; cat "$actual"; } | sort -u >"$temp"
  cmp -s "$temp" "$declared" || blocked 'manifest does not match Role boundary identities'
  cp -- "$declared" "$cumulative"; chmod 600 "$cumulative"
  printf '%s\n' "$call_dir"
}
assert_publish() {
  safe_name "$expected" || blocked 'unsafe fingerprint name'
  [[ -d "$fingerprints/$expected" ]] || blocked 'expected fingerprint is unavailable'
  local current="publish-$(date -u +%Y%m%dT%H%M%SZ)-$RANDOM"
  name=$current; capture >/dev/null
  cmp -s "$fingerprints/$expected/digest" "$fingerprints/$current/digest" || blocked 'worktree differs from reviewed fingerprint'
  printf '%s\n' "$fingerprints/$current"
}
case $command in
  capture) capture;;
  new-call-id) new_call_id;;
  record-role) record_role;;
  assert-publish) assert_publish;;
esac
