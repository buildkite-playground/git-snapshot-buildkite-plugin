#!/usr/bin/env bash
# Shared configuration and Cache contract for the pre/post-checkout hooks.
workers="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_CHECKOUT_WORKERS:-8}"
max_age="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE:-86400}"
refresh="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH:-true}"
refresh_only="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY:-false}"
prefix="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_KEY_PREFIX:-git-snapshot-v2}"
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
  git -c core.hooksPath=/dev/null -c gc.auto=0 "$@"
}

cache_config() {
  export GIT_SNAPSHOT_PREFIX="$prefix"
  export GIT_SNAPSHOT_REPO
  GIT_SNAPSHOT_REPO="$(printf '%s' "$repo" | git hash-object --stdin)"
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
  rm -f .git/config
  git_cmd config core.repositoryformatversion 0
  git_cmd config core.bare false
  git_cmd config remote.origin.url "$repo"
  git_cmd config remote.origin.fetch '+refs/heads/*:refs/remotes/origin/*'
  git_cmd config remote.origin.promisor true
  git_cmd config remote.origin.partialclonefilter blob:none
  git_cmd config checkout.workers "$workers"
  git_cmd config checkout.thresholdForParallelism 1
}
