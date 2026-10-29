#!/usr/bin/env bats

setup() {
  export TEST_CACHE="$BATS_TEST_TMPDIR/cache"
  mkdir -p "$TEST_CACHE" "$BATS_TEST_TMPDIR/bin"
  ln -s "$BATS_TEST_DIRNAME/cache-agent" "$BATS_TEST_TMPDIR/bin/buildkite-agent"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
  export GIT_AUTHOR_NAME=Test GIT_AUTHOR_EMAIL=test@example.com
  export GIT_COMMITTER_NAME=Test GIT_COMMITTER_EMAIL=test@example.com
  source_repo="$BATS_TEST_TMPDIR/source"
  git init -q --initial-branch=main "$source_repo"
  git -C "$source_repo" config uploadpack.allowFilter true
  git -C "$source_repo" config uploadpack.allowAnySHA1InWant true
  printf 'old contents\n' > "$source_repo/file"
  git -C "$source_repo" add .
  git -C "$source_repo" commit -qm first
  old="$(git -C "$source_repo" rev-parse HEAD)"
  printf 'new contents\n' > "$source_repo/file"
  printf 'second file\n' > "$source_repo/added"
  git -C "$source_repo" add .
  git -C "$source_repo" commit -qm second
  latest="$(git -C "$source_repo" rev-parse HEAD)"
  git -C "$source_repo" update-ref refs/pull/7/head "$latest"
  export BUILDKITE_REPO="file://$source_repo"
  export BUILDKITE_BUILD_CHECKOUT_PATH="$BATS_TEST_TMPDIR/checkout"
  export BUILDKITE_COMMIT="$old" BUILDKITE_BRANCH=main
  export BUILDKITE_SKIP_CHECKOUT=false
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS=false
  unset BUILDKITE_GIT_MIRRORS_PATH BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS
  hook="$BATS_TEST_DIRNAME/../hooks/pre-checkout"
  post_hook="$BATS_TEST_DIRNAME/../hooks/post-checkout"
}

assert_checkout() {
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse HEAD)" = "$1" ]
  [ -z "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" status --porcelain)" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.promisor)" = true ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.partialclonefilter)" = "${2:-blob:none}" ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/objects/info/alternates" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse --is-shallow-repository)" = false ]
}

rg_count_saves() {
  # No ripgrep dependency in the plugin-tester image.
  grep -c "^save ${1:-snapshot} " "$TEST_CACHE/operations"
}

offline_git() {
  GIT_NO_LAZY_FETCH=1 GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" "$@"
}

# What the agent's checkout does between the hooks. With skip-fetch it runs no
# fetch, though checkout can still lazily fetch objects the restore lacks.
agent_checkout() {
  local target="$BUILDKITE_COMMIT"
  if [[ "${BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS:-}" != true ]]; then
    if [[ "$target" == HEAD ]]; then
      git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" fetch -q origin "$BUILDKITE_BRANCH" || return
      target=FETCH_HEAD
    else
      git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" fetch -q origin "$target" || return
    fi
  fi
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" checkout -qf "$target"
}

# One job on a fresh agent. Run it in a subshell (`run job` or `( job )`) so
# hook exports end with the job, as they do in the agent.
job() {
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  source "$hook" || return
  agent_checkout || return
  source "$post_hook" || return
  echo "skip-fetch=${BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS:-unset} skip-checkout=$BUILDKITE_SKIP_CHECKOUT"
}

@test "cold miss saves only Git metadata, HEAD blobs are local, history blobs stay promised" {
  export BUILDKITE_COMMIT="$latest"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  assert_checkout "$latest"
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 1 ]
  [ ! -e "$(find "$TEST_CACHE" -name .git)/../file" ]
  run offline_git rev-list --objects --missing=print "$latest^{tree}"
  [ "$status" -eq 0 ]
  [[ "$output" != *'?'* ]]
  historical_blob="$(git -C "$source_repo" rev-parse "$old:file")"
  run offline_git cat-file -e "$historical_blob"
  [ "$status" -ne 0 ]
  # A history-walking command can fetch from the retained promisor remote.
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" show "$old:file")" = 'old contents' ]
}

@test "the agent owns checkout even when a removed mode option is set" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_MODE=checkout
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'mode option was removed'* && "$output" == *'skip-checkout=false'* ]]
  assert_checkout "$old"
}

@test "warm restore at the snapshot commit needs no upstream access" {
  ( job )
  # Any contact with origin now fails, so a pass proves the job stayed local.
  mv "$source_repo" "$source_repo.unreachable"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* && "$output" == *'skip-fetch=true'* ]]
  assert_checkout "$old"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'old contents' ]
  [ "$(rg_count_saves)" -eq 1 ]
  run grep -q ' patch ' "$TEST_CACHE/operations"
  [ "$status" -ne 0 ]
}

@test "stale fallback keeps refs, fetches only the delta, and saves the current period" {
  git -C "$source_repo" reset -q --hard "$old"
  git -C "$source_repo" tag seed "$old"
  ( job )
  snapshot="$(find "$TEST_CACHE" -name .git)"
  [ "$(git --git-dir="$snapshot" rev-parse refs/tags/seed)" = "$old" ]
  period_dir="$(dirname "$snapshot")"
  period="$(basename "$period_dir")"
  echo "$(( $(date +%s) - 90000 ))" > "$snapshot/git-snapshot-created-at"
  mv "$period_dir" "$(dirname "$period_dir")/$((period - 1))"
  git -C "$source_repo" reset -q --hard "$latest"
  export BUILDKITE_COMMIT="$latest"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* && "$output" == *'patch hit=false'* ]]
  assert_checkout "$latest"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 2 ]
  [ "$(rg_count_saves)" -eq 2 ]
  [ "$(rg_count_saves patch)" -eq 1 ]
  # The agent's plain fetch must not download a second copy of the snapshot's
  # commits and trees into another pack.
  expected_objects="$(git -C "$source_repo" rev-list --objects --all | wc -l)"
  packed_objects="$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" count-objects -v | sed -n 's/^in-pack: //p')"
  [ "$packed_objects" -eq "$expected_objects" ]
}

@test "restore and save errors do not fail the job" {
  export TEST_RESTORE_ERROR=true TEST_SAVE_ERROR=true
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'cache save failed'* ]]
  assert_checkout "$old"
}

@test "read-only jobs save neither snapshots nor patches" {
  ( job )
  export BUILDKITE_COMMIT="$latest" BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH=false
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'patch hit=false'* ]]
  assert_checkout "$latest"
  [ "$(rg_count_saves)" -eq 1 ]
  [ "$(rg_count_saves patch)" -eq 0 ]
}

@test "refresh-only saves once per key period; other jobs wait for max-age" {
  # Keep the whole test inside one key period of the default max-age.
  remaining=$(( 86400 - $(date +%s) % 86400 ))
  if (( remaining < 60 )); then sleep "$remaining"; fi
  ( job )
  snapshot="$(find "$TEST_CACHE" -name .git)"
  period_dir="$(dirname "$snapshot")"
  period="$(basename "$period_dir")"
  # Saved in the last second of the previous period: younger than max-age.
  echo "$(( period * 86400 - 1 ))" > "$snapshot/git-snapshot-created-at"
  mv "$period_dir" "$(dirname "$period_dir")/$((period - 1))"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  [ "$(rg_count_saves)" -eq 1 ]
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY=true
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'refresh-only=true'* ]]
  [ "$(rg_count_saves)" -eq 2 ]
  [ -d "$period_dir/.git" ]
  assert_checkout "$old"
  # This period now has a snapshot.
  run job
  [ "$status" -eq 0 ]
  [ "$(rg_count_saves)" -eq 2 ]
}

@test "rejects invalid config, unsafe paths and embedded HTTP credentials" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE=86401
  run "$hook"
  [ "$status" -ne 0 ]
  unset BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE
  export BUILDKITE_BUILD_CHECKOUT_PATH=/
  run "$hook"
  [ "$status" -ne 0 ]
  export BUILDKITE_BUILD_CHECKOUT_PATH="$BATS_TEST_TMPDIR/checkout"
  export BUILDKITE_REPO=https://secret@example.com/repo.git
  run "$hook"
  [ "$status" -ne 0 ]
  [[ "$output" != *secret* ]]
}

@test "treeless snapshots isolate keys, keep HEAD local and historical trees missing" {
  export BUILDKITE_COMMIT="$latest"
  ( job )
  unset BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  [[ "$output" == *'treeless active; set treeless: false'* ]]
  assert_checkout "$latest" tree:0
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'new contents' ]
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 2 ]
  run offline_git rev-list --objects --missing=print 'HEAD^{tree}'
  [ "$status" -eq 0 ]
  [[ "$output" != *'?'* ]]
  historical_tree="$(git -C "$source_repo" rev-parse "$old^{tree}")"
  run offline_git cat-file -e "$historical_tree"
  [ "$status" -ne 0 ]
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS=false
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  [[ "$output" != *'treeless active'* ]]
  assert_checkout "$latest"
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 2 ]
}

@test "with mirrors enabled the hooks never restore or save" {
  export BUILDKITE_GIT_MIRRORS_PATH="$BATS_TEST_TMPDIR/mirrors"
  source "$hook"
  source "$post_hook"
  [ "$BUILDKITE_SKIP_CHECKOUT" = false ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git" ]
  [ ! -e "$TEST_CACHE/operations" ]
}

patch_round_trip() {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS="$1"
  ( job )
  printf 'third contents\n' > "$source_repo/file"
  git -C "$source_repo" commit -qam third
  newest="$(git -C "$source_repo" rev-parse HEAD)"
  export BUILDKITE_COMMIT="$newest"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* && "$output" == *'patch hit=false'* ]]
  [ "$(rg_count_saves patch)" -eq 1 ]
  # Any contact with origin now fails, so a pass proves the hit stayed local.
  mv "$source_repo" "$source_repo.unreachable"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'patch hit=true'* && "$output" == *'skip-fetch=true'* ]]
  assert_checkout "$newest" "$2"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'third contents' ]
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(rg_count_saves patch)" -eq 1 ]
  # Omitted objects are promised by the patch pack, so integrity checks still pass.
  offline_git fsck --connectivity-only --no-dangling
  # The intermediate commit's blob stays promised. Its tree came with the
  # blobless snapshot's clone; treeless leaves it promised too.
  run offline_git cat-file -e "$(git -C "$source_repo.unreachable" rev-parse "$latest:file")"
  [ "$status" -ne 0 ]
  run offline_git cat-file -e "$(git -C "$source_repo.unreachable" rev-parse "$latest^{tree}")"
  [ "$status" "$3" 0 ]
}

@test "a patch miss saves, the next job checks out offline (blobless)" {
  patch_round_trip false blob:none -eq
}

@test "a patch miss saves, the next job checks out offline (treeless)" {
  patch_round_trip true tree:0 -ne
}

@test "corrupt or incomplete patches fall back to origin with an exact checkout" {
  ( job )
  export BUILDKITE_COMMIT="$latest"
  ( job )
  bundle="$(find "$TEST_CACHE/patch" -name git-snapshot.bundle)"
  # Valid bundle and prerequisites, but none of the target's new blobs.
  git -C "$source_repo" bundle create -q "$bundle" --filter=blob:none main "^$old"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'patch hit=false'* ]]
  assert_checkout "$latest"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'new contents' ]
  printf 'not a bundle\n' > "$bundle"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'patch hit=false'* ]]
  assert_checkout "$latest"
}

@test "a HEAD build saves its patch under the resolved commit; later jobs skip the agent fetch" {
  git -C "$source_repo" reset -q --hard "$old"
  ( job )
  git -C "$source_repo" reset -q --hard "$latest"
  # The first job of a build may only know the branch.
  export BUILDKITE_COMMIT=HEAD
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'skip-fetch=unset'* && "$output" != *'patch hit='* ]]
  [ "$(rg_count_saves patch)" -eq 1 ]
  mv "$source_repo" "$source_repo.unreachable"
  export BUILDKITE_COMMIT="$latest"
  run job
  [ "$status" -eq 0 ]
  [[ "$output" == *'patch hit=true'* && "$output" == *'skip-fetch=true'* ]]
  assert_checkout "$latest"
}

@test "turns off agent skip-fetch for a commit the restore lacks" {
  export BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS=true
  git -C "$source_repo" reset -q --hard "$old"
  export BUILDKITE_COMMIT="$latest"
  source "$hook"
  [ -d "$BUILDKITE_BUILD_CHECKOUT_PATH/.git" ]
  [ "$BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS" = false ]
}

@test "patches: false neither restores nor saves patches" {
  ( job )
  export BUILDKITE_COMMIT="$latest" BUILDKITE_PLUGIN_GIT_SNAPSHOT_PATCHES=false
  run job
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
  run grep -q ' patch ' "$TEST_CACHE/operations"
  [ "$status" -ne 0 ]
}
