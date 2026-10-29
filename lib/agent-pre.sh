#!/usr/bin/env bash
(
set -euo pipefail
# shellcheck source=lib/snapshot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/snapshot.sh"

case "${BUILDKITE_CLEAN_CHECKOUT:-false}:${BUILDKITE_SKIP_CHECKOUT:-false}" in
  false:false|0:0|false:0|0:false) ;;
  *) echo 'git-snapshot: clean/skip checkout requested; leaving checkout to the agent'; exit 0 ;;
esac
if [[ -e "$checkout/.git" ]]; then
  echo 'git-snapshot: existing checkout; leaving it to the agent'
  exit 0
fi
if [[ "$treeless" == true ]]; then
  echo 'git-snapshot: treeless active; set treeless: false for path-history jobs'
fi

scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/snapshot"
cache_config
cd "$scratch/snapshot"
started=$SECONDS
hit=false
created=0
if cache restore && [[ -d .git && ! -L .git && -f .git/git-snapshot-created-at ]]; then
  read -r created < .git/git-snapshot-created-at || created=0
  if [[ "$created" =~ ^[0-9]+$ ]] && (( created > 0 && created <= now )) &&
    [[ ! -e .git/shallow && ! -e .git/objects/info/alternates ]] &&
    GIT_ALLOW_PROTOCOL='' git_cmd cat-file -e 'HEAD^{tree}'; then
    hit=true
  fi
fi
if [[ "$hit" == false ]]; then
  rm -rf .git
  # Clone creates real refs before the agent's SHA and verification fetches.
  # An empty init would fetch history twice before either fetch leaves a ref.
  if ! git_cmd clone --filter="$filter" --no-checkout --template= -- "$repo" .; then
    # Agent-managed SSH credentials may only become available during checkout.
    rm -rf .git
    git_cmd init --template= .
  fi
else
  # Never reuse an index: an unchanged HEAD must still materialize every file.
  rm -f .git/index
fi
configure_origin
echo "git-snapshot: restore hit=$hit seconds=$((SECONDS - started)); agent owns checkout"
if [[ "$hit" == true ]]; then
  base="$(git_cmd rev-parse HEAD)"
  # Repair old detached-HEAD snapshots too: plain agent fetch must advertise history.
  git_cmd update-ref refs/heads/buildkite-snapshot "$base"
  commit="${BUILDKITE_COMMIT:-HEAD}"
  # A pinned commit may arrive in its patch. Otherwise, including HEAD and branch
  # builds, post-checkout saves a patch for the commit the agent checked out.
  if [[ "$patches" == true && "$commit" != "$base" ]] &&
     { [[ ! "$commit" =~ ^[0-9a-f]{40}$ ]] || ! restore_patch "$base" "$commit"; }; then
    echo "$base" > .git/git-snapshot-patch-base
  fi
fi
# Tell the hook whether the agent may skip its fetch: only for an exact local commit.
# rev-list --missing never tries a lazy fetch. Git 2.43's other lookups scan every
# promisor object after refusing one: ~20s (blobless ~110s) for a missing Linux commit.
if [[ "${BUILDKITE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]]; then
  if offline git_cmd rev-list --missing=print --no-walk "$BUILDKITE_COMMIT^{commit}" >/dev/null 2>&1; then
    echo present > .git/git-snapshot-commit
  else
    echo missing > .git/git-snapshot-commit
  fi
fi
mkdir -p "$checkout"
mv .git "$checkout/.git"
)
