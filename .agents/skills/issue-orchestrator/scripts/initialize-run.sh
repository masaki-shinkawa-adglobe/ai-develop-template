#!/usr/bin/env bash
# Creates the private filesystem record for one *new* Issue Agent Run.
set -euo pipefail

blocked() {
  # This is intentionally the only failure output.  Callers can retain the safe
  # identifiers after a late failure without receiving a private path, URL, or OS
  # diagnostic that could be surfaced in a public status summary.
  local issue_field run_field repository_field
  if [[ ${issue_number:-} =~ ^[1-9][0-9]*$ ]]; then issue_field=$issue_number; else issue_field=null; fi
  if [[ ${run_id:-} =~ ^[a-f0-9]{32,128}$ ]]; then run_field="\"$run_id\""; else run_field=null; fi
  if [[ ${repository_id:-} =~ ^[a-f0-9]{64}$ ]]; then repository_field="\"$repository_id\""; else repository_field=null; fi
  printf '{"outcome":"BLOCKED","issue_number":%s,"run_id":%s,"repository_id":%s,"state":null,"safe_summary":"%s"}\n' \
    "$issue_field" "$run_field" "$repository_field" "$1"
  exit 1
}

usage() {
  printf '%s\n' 'usage: initialize-run.sh ISSUE_NUMBER [--run-id RUN_ID]' >&2
  exit 2
}

issue_number=${1:-}
shift || true
[[ $issue_number =~ ^[1-9][0-9]*$ ]] || usage

run_id=''
while (($#)); do
  case $1 in
    --run-id)
      (($# >= 2)) || usage
      run_id=$2
      shift 2
      ;;
    *) usage ;;
  esac
done

if [[ -z $run_id ]]; then
  run_id=$({ od -An -N32 -tx1 /dev/urandom | tr -d ' \n'; } 2>/dev/null) || blocked 'run ID could not be generated'
fi
[[ $run_id =~ ^[a-f0-9]{32,128}$ ]] || blocked 'run ID has an unsafe format'

if [[ -n ${ISSUE_AGENT_STATE_DIR+x} ]]; then
  state_root=$ISSUE_AGENT_STATE_DIR
  root_is_explicit=true
else
  [[ -n ${HOME:-} ]] || blocked 'default state root cannot be determined'
  state_base=${XDG_STATE_HOME:-"$HOME/.local/state"}
  state_root="$state_base/issue-agent-runs"
  root_is_explicit=false
fi
[[ -n $state_root && $state_root = /* ]] || blocked 'state root must be an absolute path'
# test -L follows a trailing separator on many systems.  Remove it first so a
# configured symlink root is always inspected as the link itself (except /).
while [[ $state_root != / && $state_root == */ ]]; do state_root=${state_root%/}; done

uid=$(id -u 2>/dev/null) || blocked 'effective user could not be determined'

verify_directory() {
  local path=$1 resolved mode owner
  [[ ! -L $path ]] || blocked 'state directory is a symbolic link'
  [[ -d $path ]] || blocked 'state directory is not a directory'
  owner=$(stat -c '%u' -- "$path" 2>/dev/null) || blocked 'state directory could not be inspected'
  [[ $owner == "$uid" ]] || blocked 'state directory is not owned by the effective user'
  mode=$(stat -c '%a' -- "$path" 2>/dev/null) || blocked 'state directory could not be inspected'
  [[ $mode == 700 ]] || blocked 'state directory permissions are not private'
  resolved=$(realpath -e -- "$path" 2>/dev/null) || blocked 'state directory could not be resolved'
  if [[ -n ${resolved_root:-} && $resolved != "$resolved_root" && $resolved != "$resolved_root"/* ]]; then
    blocked 'state directory resolves outside the state root'
  fi
}

if [[ ! -e $state_root && ! -L $state_root ]]; then
  # A caller selecting ISSUE_AGENT_STATE_DIR must provision it beforehand.  The
  # standard root is the only root this explicit initializer may create.
  [[ $root_is_explicit == false ]] || blocked 'configured state root does not exist'
  mkdir -p -m 700 -- "$state_root" 2>/dev/null || blocked 'standard state root could not be created'
fi
verify_directory "$state_root"
resolved_root=$(realpath -e -- "$state_root" 2>/dev/null) || blocked 'state root could not be resolved'

remote_url=$(git remote get-url origin 2>/dev/null) || blocked 'origin remote could not be determined'
[[ -n $remote_url ]] || blocked 'origin remote could not be determined'

# Strip URL userinfo (including passwords/tokens) and normalise only the spelling
# differences specified by the Run contract.  SCP-style git@host:path drops git@.
normalised_url=$remote_url
if [[ $normalised_url =~ ^([A-Za-z][A-Za-z0-9+.-]*://)([^/?#]*)(.*)$ ]]; then
  authority=${BASH_REMATCH[2]}
  # Only the authority can contain userinfo.  A path/query fragment may legally
  # include @ and must remain part of the repository identity.
  normalised_url="${BASH_REMATCH[1]}${authority##*@}${BASH_REMATCH[3]}"
elif [[ $normalised_url =~ ^[^/@:]+@([^:]+:.+)$ ]]; then
  normalised_url=${BASH_REMATCH[1]}
fi
while [[ $normalised_url == */ ]]; do normalised_url=${normalised_url%/}; done
if [[ $normalised_url == *.git ]]; then normalised_url=${normalised_url%.git}; fi
while [[ $normalised_url == */ ]]; do normalised_url=${normalised_url%/}; done
[[ -n $normalised_url ]] || blocked 'origin remote has an unsafe format'
repository_id=$({ printf '%s' "$normalised_url" | sha256sum | awk '{print $1}'; } 2>/dev/null) || blocked 'repository ID could not be generated'
[[ $repository_id =~ ^[a-f0-9]{64}$ ]] || blocked 'repository ID could not be generated'

repository_dir="$state_root/$repository_id"
issue_dir="$repository_dir/$issue_number"
for directory in "$repository_dir" "$issue_dir"; do
  if [[ ! -e $directory && ! -L $directory ]]; then
    mkdir -m 700 -- "$directory" 2>/dev/null || blocked 'state directory could not be created'
  fi
  verify_directory "$directory"
done

run_dir="$issue_dir/$run_id"
if [[ -e $run_dir || -L $run_dir ]]; then
  blocked 'a Run directory with this run ID already exists'
fi
mkdir -m 700 -- "$run_dir" 2>/dev/null || blocked 'Run directory could not be created'
verify_directory "$run_dir"

created_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null) || blocked 'creation time could not be generated'
state_file="$run_dir/run.json"
(
  umask 077
  set -C
  printf '{"run_id":"%s","repository_id":"%s","issue_number":%s,"state":"PLANNING","created_at":"%s"}\n' \
    "$run_id" "$repository_id" "$issue_number" "$created_at" >"$state_file"
) 2>/dev/null || blocked 'initial Run state could not be saved'
chmod 600 -- "$state_file" 2>/dev/null || blocked 'initial Run state could not be secured'

printf '{"outcome":"INITIALIZED","run_id":"%s","repository_id":"%s","issue_number":%s,"state":"PLANNING","created_at":"%s"}\n' \
  "$run_id" "$repository_id" "$issue_number" "$created_at"
