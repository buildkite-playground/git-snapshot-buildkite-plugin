#!/usr/bin/env bash
(
set -euo pipefail
started=$SECONDS
# shellcheck source=lib/snapshot.sh
source "$(dirname "${BASH_SOURCE[0]}")/snapshot.sh"
commit="${BUILDKITE_COMMIT:-HEAD}"
if [[ "$treeless" == true ]]; then
  echo 'git-snapshot: treeless active; set treeless: false for path-history jobs'
fi

# Restore into an empty, job-private directory: a successful CLI exit can be a miss.
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
mkdir "$scratch/snapshot"
cache_config

fetch_checkout() {
  local ref target fetch_start checkout_start
  local -a fetch_flags=(--filter="$filter")
  fetch_start=$SECONDS
  # A detached HEAD is not advertised by Git's default ref-based negotiation.
  # Include it explicitly, including for snapshots saved by older versions.
  if git_cmd rev-parse --verify HEAD >/dev/null 2>&1; then
    fetch_flags+=(--negotiation-tip=HEAD)
  fi
  ref="${BUILDKITE_REFSPEC:-}"
  if [[ -z "$ref" && "${BUILDKITE_PULL_REQUEST:-false}" != false && -n "${BUILDKITE_PULL_REQUEST:-}" && "$repo" == *github.com* ]]; then
    ref="refs/pull/${BUILDKITE_PULL_REQUEST}/head"
    if [[ "${BUILDKITE_PULL_REQUEST_USING_MERGE_REFSPEC:-false}" == true ]]; then
      ref="refs/pull/${BUILDKITE_PULL_REQUEST}/merge"
    fi
  fi
  if [[ -n "$ref" ]]; then
    git_cmd fetch "${fetch_flags[@]}" -- origin "$ref" || return
  elif [[ "$commit" == HEAD ]]; then
    git_cmd fetch "${fetch_flags[@]}" -- origin "${BUILDKITE_BRANCH:-HEAD}" || return
  else
    git_cmd fetch "${fetch_flags[@]}" -- origin "$commit" || return
  fi
  if [[ "$commit" == HEAD ]]; then
    target="$(git_cmd rev-parse --verify 'FETCH_HEAD^{commit}')" || return
  else
    # A force-pushed PR ref may no longer contain the build's pinned SHA.
    if ! git_cmd cat-file -e "${commit}^{commit}"; then
      git_cmd fetch "${fetch_flags[@]}" -- origin "$commit" || return
    fi
    target="$(git_cmd rev-parse --verify "${commit}^{commit}")" || return
  fi
  echo "git-snapshot: fetch seconds=$((SECONDS - fetch_start))"
  checkout_start=$SECONDS
  git_cmd -c checkout.workers="$workers" -c checkout.thresholdForParallelism=1 \
    checkout --force --detach "$target" || return
  echo "git-snapshot: checkout seconds=$((SECONDS - checkout_start))"
  [[ "$(git_cmd rev-parse HEAD)" == "$target" ]]
}

cd "$scratch/snapshot"
restore_start=$SECONDS
hit=false
created=0
if cache restore && [[ -d .git && ! -L .git && -f .git/git-snapshot-created-at ]]; then
  read -r created < .git/git-snapshot-created-at || created=0
  if [[ "$created" =~ ^[0-9]+$ ]] && (( created > 0 && created <= now )); then
    hit=true
  fi
fi
echo "git-snapshot: restore hit=$hit seconds=$((SECONDS - restore_start))"

checkout_start=$SECONDS
if [[ "$hit" == true ]]; then
  # Restores have no worktree, even when HEAD has not changed.
  rm -f .git/index
  if ! configure_origin || ! fetch_checkout; then
    echo 'git-snapshot: snapshot unusable; retrying a fresh partial checkout' >&2
    hit=false
  fi
fi
if [[ "$hit" == false ]]; then
  # A failed checkout may have left partially materialized files as well as Git
  # metadata. Do not carry either into the fresh retry.
  find . -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  git_cmd init .
  configure_origin
  fetch_checkout
  created=0
fi
echo "git-snapshot: fetch+checkout seconds=$((SECONDS - checkout_start)) commit=$(git_cmd rev-parse HEAD)"

# Checkout hydrates HEAD's blobs before saving. Never archive the worktree.
if [[ "$refresh" == true ]] && (( now - created >= max_age )); then
  git_cmd update-ref refs/heads/buildkite-snapshot HEAD
  date +%s > .git/git-snapshot-created-at
  save_start=$SECONDS
  if ! cache save; then
    echo 'git-snapshot: cache save failed; checkout remains usable' >&2
  fi
  echo "git-snapshot: save seconds=$((SECONDS - save_start))"
fi

if [[ "$refresh_only" == true ]]; then
  echo 'git-snapshot: refresh-only; no worktree installed (use command: ":")'
else
  # The agent owns this dedicated checkout path. Remove tracked, ignored and
  # untracked leftovers, including nested repositories, before installing it.
  find "$checkout" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
  shopt -s dotglob nullglob
  mv -- "$scratch/snapshot/"* "$checkout/"
fi
echo "git-snapshot: total seconds=$((SECONDS - started))"
)
