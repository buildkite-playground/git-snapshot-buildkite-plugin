#!/usr/bin/env bash
# Shared configuration and Cache contract for the pre/post-checkout hooks.
workers="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_CHECKOUT_WORKERS:-8}"
max_age="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE:-86400}"
refresh="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH:-true}"
refresh_only="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY:-false}"
treeless="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS:-false}"
filter=blob:none
[[ "$treeless" == false || "$treeless" == true ]] || {
  echo 'git-snapshot: treeless must be true or false' >&2; exit 1;
}
if [[ "$treeless" == true ]]; then filter=tree:0; fi
prefix="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_KEY_PREFIX:-git-snapshot-v3}"
repo="${BUILDKITE_REPO:?BUILDKITE_REPO is required}"
checkout="${BUILDKITE_BUILD_CHECKOUT_PATH:?BUILDKITE_BUILD_CHECKOUT_PATH is required}"
[[ "$workers" =~ ^[1-9][0-9]*$ && "$max_age" =~ ^[1-9][0-9]*$ ]] || {
  echo 'git-snapshot: workers and max-age must be positive integers' >&2; exit 1;
}
(( max_age <= 86400 )) || { echo 'git-snapshot: max-age must be <= 86400 seconds' >&2; exit 1; }
[[ "$refresh" =~ ^(true|false)$ && "$refresh_only" =~ ^(true|false)$ ]] || exit 1
[[ ! "$repo" =~ ^https?://[^/]*@ ]] || {
  echo 'git-snapshot: use a credential helper, not credentials in the repository URL' >&2; exit 1;
}
[[ "$checkout" = /* && "$checkout" != / && "$checkout" != "${HOME:-/}" && ! -L "$checkout" ]] || {
  echo 'git-snapshot: checkout must be a dedicated absolute directory, not a symlink' >&2; exit 1;
}
mkdir -p "$checkout"
checkout="$(cd "$checkout" && pwd -P)"
[[ "$checkout" != / && "$checkout" != "${HOME:-/}" ]] || exit 1
now="$(date +%s)"
scratch=''

git_cmd() {
  git -c core.hooksPath=/dev/null -c gc.auto=0 -c fetch.recurseSubmodules=false "$@"
}

cache_config() {
  export GIT_SNAPSHOT_PREFIX="$prefix"
  export GIT_SNAPSHOT_REPO
  GIT_SNAPSHOT_REPO="$(printf '%s\n%s' "$repo" "$filter" | git hash-object --stdin)"
  export GIT_SNAPSHOT_PERIOD="$((now / max_age))"
  cat > "$scratch/cache.yml" <<'YAML'
caches:
  - name: git_snapshot
    cache_key:
      - env: GIT_SNAPSHOT_PREFIX
      - env: GIT_SNAPSHOT_REPO
        fallback_limit: true
      - env: GIT_SNAPSHOT_PERIOD
    target_paths:
      - .git
YAML
}

cache() {
  buildkite-agent cache "$1" --cache-config-file "$scratch/cache.yml" \
    --cache-fail-on-error --no-color
}

configure_origin() {
  rm -f .git/config || return
  git_cmd config core.repositoryformatversion 0 || return
  git_cmd config core.bare false || return
  git_cmd config remote.origin.url "$repo" || return
  git_cmd config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*' || return
  git_cmd config remote.origin.promisor true || return
  git_cmd config remote.origin.partialclonefilter "$filter" || return
  git_cmd config fetch.recurseSubmodules false || return
  git_cmd config gc.auto 0 || return
  git_cmd config checkout.workers "$workers" || return
  git_cmd config checkout.thresholdForParallelism 1
}
