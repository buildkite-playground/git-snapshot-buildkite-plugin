#!/usr/bin/env bash
# Shared configuration and Cache contract for the pre/post-checkout hooks.
workers="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_CHECKOUT_WORKERS:-8}"
max_age="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE:-86400}"
refresh="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH:-true}"
refresh_only="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY:-false}"
patches="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_PATCHES:-true}"
treeless="${BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS:-true}"
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
[[ "$refresh" =~ ^(true|false)$ && "$refresh_only" =~ ^(true|false)$ && "$patches" =~ ^(true|false)$ ]] || exit 1
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

# Local-only Git: a missing object fails instead of lazily fetching from origin.
# The empty protocol allow-list covers Git without GIT_NO_LAZY_FETCH (before 2.43.4/2.45.1).
offline() {
  GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL='' "$@"
}

# A patch holds what a snapshot at $1 lacks to check out $2. Keys are exact:
# a fallback could only return objects for some other commit.
patch_cache() {
  cat > "$scratch/patch.yml" <<'YAML'
caches:
  - name: git_snapshot_patch
    cache_key:
      - env: GIT_SNAPSHOT_PREFIX
      - patch
      - env: GIT_SNAPSHOT_REPO
      - env: GIT_SNAPSHOT_BASE
      - env: GIT_SNAPSHOT_TARGET
    target_paths:
      - patch
YAML
  (cd "$scratch" && GIT_SNAPSHOT_BASE="$2" GIT_SNAPSHOT_TARGET="$3" \
    buildkite-agent cache "$1" --cache-config-file patch.yml --cache-fail-on-error --no-color)
}

# Checkout of $2 needs no network: commits back to snapshot $1 and the whole tree are local.
checkout_ready() {
  local missing
  missing="$({
    offline git_cmd rev-list --missing=print "$2" "^$1" &&
    offline git_cmd rev-list --objects --no-object-names --missing=print "$2^{tree}"
  } | awk '/^[?]/ { n++ } END { print n + 0 }')" || return
  [[ "$missing" == 0 ]]
}

# Restore and apply the patch from snapshot $1 to $2 in the current repository.
# Objects are content-addressed, so a bad patch can only be incomplete; reject that too.
restore_patch() {
  local started=$SECONDS bundle="$scratch/patch/git-snapshot.bundle"
  rm -rf "$scratch/patch"
  if patch_cache restore "$1" "$2" && [[ -f "$bundle" && ! -L "$bundle" ]] &&
     offline git_cmd bundle verify --quiet "$bundle" &&
     offline git_cmd bundle unbundle "$bundle" >/dev/null &&
     checkout_ready "$1" "$2"; then
    # Advertise the target in negotiation for any later fetch.
    git_cmd update-ref refs/buildkite-snapshot/patch "$2" || return
    echo "git-snapshot: patch hit=true snapshot=$1 bytes=$(wc -c < "$bundle") seconds=$((SECONDS - started))"
    return 0
  fi
  echo "git-snapshot: patch hit=false snapshot=$1 seconds=$((SECONDS - started)); fetching from origin"
  return 1
}

# Objects that the snapshot at $1 lacks to check out $2, filtered like the
# snapshot: treeless leaves intermediate trees promised, blobless carries them.
patch_objects() {
  if [[ "$treeless" == true ]]; then
    offline git_cmd rev-list "$2" "^$1" || return
  else
    offline git_cmd rev-list --objects --filter=blob:none --missing=allow-any "$2" "^$1" || return
  fi
  offline git_cmd rev-list --objects --missing=allow-any "$2^{tree}" "^$1^{tree}"
}

# Save the patch from snapshot $1 to $2 from the current, checked-out repository.
# A v3 bundle with a filter unbundles as a promisor pack, so the trees and blobs
# it intentionally omits stay lazily fetchable like the snapshot's own.
save_patch() {
  local started=$SECONDS dir="$scratch/patch"
  [[ "$patches" == true && "$refresh" == true && -n "$1" && "$1" != "$2" ]] || return 0
  if ! checkout_ready "$1" "$2"; then
    echo 'git-snapshot: target objects incomplete; skipping patch save'
    return 0
  fi
  rm -rf "$dir" && mkdir "$dir" || return
  {
    printf '# v3 git bundle\n@object-format=sha1\n@filter=%s\n-%s snapshot\n%s refs/buildkite-snapshot/patch\n\n' \
      "$filter" "$1" "$2"
    patch_objects "$1" "$2" | offline git_cmd pack-objects --stdout -q
  } > "$dir/git-snapshot.bundle" || return
  patch_cache save "$1" "$2" || return
  echo "git-snapshot: patch save bytes=$(wc -c < "$dir/git-snapshot.bundle") seconds=$((SECONDS - started))"
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
