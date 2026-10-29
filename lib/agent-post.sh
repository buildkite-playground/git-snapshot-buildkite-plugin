#!/usr/bin/env bash
(
set -euo pipefail
# shellcheck source=lib/snapshot.sh
source "$(dirname "${BASH_SOURCE[0]}")/../lib/snapshot.sh"

[[ "$refresh" == true && "${BUILDKITE_SKIP_CHECKOUT:-false}" == false ]] || exit 0
cd "$checkout"
# Never publish a shallow, mirror-dependent, or ordinary full clone as a snapshot.
if [[ ! -d .git || -L .git || -e .git/shallow || -e .git/objects/info/alternates ||
      -n "${GIT_ALTERNATE_OBJECT_DIRECTORIES:-}" ]] ||
   [[ "$(git_cmd config --get remote.origin.promisor || true)" != true ||
      "$(git_cmd config --get remote.origin.partialclonefilter || true)" != "$filter" ]]; then
  echo 'git-snapshot: not an independent partial repository; skipping save'
  exit 0
fi

# Cache preparation (including disk exhaustion) must not fail a usable checkout.
set -E
trap 'echo "git-snapshot: snapshot save failed; agent checkout remains usable" >&2; exit 0' ERR
scratch="$(mktemp -d)"
trap 'rm -rf -- "$scratch"' EXIT
cache_config
sha="$(git_cmd rev-parse HEAD)"

# Written by this job's restore after a patch miss, including HEAD/branch builds:
# later jobs for the commit the agent resolved restore this patch instead of fetching.
if [[ -f .git/git-snapshot-patch-base ]]; then
  read -r base < .git/git-snapshot-patch-base || base=''
  rm -f .git/git-snapshot-patch-base
  if [[ "$base" =~ ^[0-9a-f]{40}$ ]] && ! save_patch "$base" "$sha"; then
    echo 'git-snapshot: patch save failed; agent checkout remains usable' >&2
  fi
fi

created=0
if [[ -f .git/git-snapshot-created-at ]]; then
  read -r created < .git/git-snapshot-created-at || created=0
fi
[[ "$created" =~ ^[0-9]+$ ]] || created=0
# Ordinary jobs refresh a snapshot once it is max-age old. A refresh-only job also
# refreshes one from an earlier key period, so a daily schedule saves every period.
if [[ "$refresh_only" == true ]]; then
  (( created < now / max_age * max_age )) || exit 0
else
  (( now - created >= max_age )) || exit 0
fi

started=$SECONDS
# Copy objects only, not agent credentials, hooks, sparse config, LFS or submodules.
# No hardlinked mutable Git metadata, and no worktree files, enter the archive.
git_cmd init --template= "$scratch/snapshot"
cp -R .git/objects/. "$scratch/snapshot/.git/objects/"
# Preserve negotiation and tag knowledge, but never auth, hooks, index, sparse,
# LFS or submodule state. Dropping tags can trigger a large auto-follow fetch.
cp -R .git/refs/. "$scratch/snapshot/.git/refs/"
if [[ -f .git/packed-refs ]]; then
  cp .git/packed-refs "$scratch/snapshot/.git/packed-refs"
fi
cd "$scratch/snapshot"
configure_origin
git_cmd symbolic-ref HEAD refs/heads/buildkite-snapshot
git_cmd update-ref refs/heads/buildkite-snapshot "$sha"
date +%s > .git/git-snapshot-created-at
if cache save; then
  cp .git/git-snapshot-created-at "$checkout/.git/git-snapshot-created-at"
else
  echo 'git-snapshot: cache save failed; agent checkout remains usable' >&2
fi
echo "git-snapshot: save seconds=$((SECONDS - started)) refresh-only=$refresh_only"
)
