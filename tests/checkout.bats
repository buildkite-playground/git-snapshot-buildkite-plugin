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
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_MODE=checkout
  unset BUILDKITE_GIT_MIRRORS_PATH
  hook="$BATS_TEST_DIRNAME/../hooks/pre-checkout"
}

assert_checkout() {
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse HEAD)" = "$1" ]
  [ -z "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" status --porcelain)" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.promisor)" = true ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.partialclonefilter)" = blob:none ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/objects/info/alternates" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse --is-shallow-repository)" = false ]
}

@test "cold miss saves only Git metadata, HEAD blobs are local, history blobs stay promised" {
  export BUILDKITE_COMMIT="$latest"
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  assert_checkout "$latest"
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 1 ]
  [ ! -e "$(find "$TEST_CACHE" -name .git)/../file" ]
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" \
    -c protocol.allow=never rev-list --objects --missing=print "$latest^{tree}"
  [ "$status" -eq 0 ]
  [[ "$output" != *'?'* ]]
  historical_blob="$(git -C "$source_repo" rev-parse "$old:file")"
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" \
    -c protocol.allow=never cat-file -e "$historical_blob"
  [ "$status" -ne 0 ]
  # A history-walking command can fetch from the retained promisor remote.
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" show "$old:file")" = 'old contents' ]
}

@test "warm restore recreates all files, removes dirty leftovers, and does not refresh" {
  initial_dir="$PWD"
  # Hooks are sourced by the agent; their cwd, traps and options must not leak.
  source "$hook"
  [ "$PWD" = "$initial_dir" ]
  [ "$BUILDKITE_SKIP_CHECKOUT" = true ]
  # The next invocation represents a separate job, not another hook in this job.
  export BUILDKITE_SKIP_CHECKOUT=false
  printf 'dirty\n' > "$BUILDKITE_BUILD_CHECKOUT_PATH/file"
  mkdir -p "$BUILDKITE_BUILD_CHECKOUT_PATH/nested/.git"
  touch "$BUILDKITE_BUILD_CHECKOUT_PATH/.ignored"
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  assert_checkout "$old"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'old contents' ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/nested" ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.ignored" ]
  [ "$(rg_count_saves)" -eq 1 ]
}

rg_count_saves() {
  # No ripgrep dependency in the plugin-tester image.
  grep -c '^save ' "$TEST_CACHE/operations"
}

@test "stale fallback fetches a newer commit and saves the current period" {
  "$hook"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  period_dir="$(dirname "$snapshot")"
  period="$(basename "$period_dir")"
  echo "$(( $(date +%s) - 90000 ))" > "$snapshot/git-snapshot-created-at"
  mv "$period_dir" "$(dirname "$period_dir")/$((period - 1))"
  export BUILDKITE_COMMIT="$latest"
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  assert_checkout "$latest"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 2 ]
  [ "$(rg_count_saves)" -eq 2 ]
  # Both revisions' blobs are now hydrated. A delta fetch must not download a
  # second copy of the existing commits and trees into another pack.
  expected_objects="$(git -C "$source_repo" rev-list --objects --all | wc -l)"
  packed_objects="$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" count-objects -v | sed -n 's/^in-pack: //p')"
  [ "$packed_objects" -eq "$expected_objects" ]
}

@test "HEAD resolves the branch or custom PR refspec, pinned commits stay pinned" {
  export BUILDKITE_COMMIT=HEAD
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
  export BUILDKITE_BRANCH=nonexistent BUILDKITE_REFSPEC=refs/pull/7/head
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
  export BUILDKITE_COMMIT="$old"
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$old"
}

@test "GitHub PR HEAD and merge refs resolve automatically without following the branch" {
  export GIT_CONFIG_GLOBAL="$BATS_TEST_TMPDIR/gitconfig"
  git config --global "url.file://$source_repo.insteadOf" https://github.com/test/repo.git
  git -C "$source_repo" update-ref refs/pull/7/merge "$old"
  export BUILDKITE_REPO=https://github.com/test/repo.git
  export BUILDKITE_COMMIT=HEAD BUILDKITE_BRANCH=nonexistent BUILDKITE_PULL_REQUEST=7
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
  export BUILDKITE_PULL_REQUEST_USING_MERGE_REFSPEC=true
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$old"
}

@test "restore error and save error do not prevent a correct fresh checkout" {
  export TEST_RESTORE_ERROR=true TEST_SAVE_ERROR=true
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'cache save failed'* ]]
  assert_checkout "$old"
}

@test "broken snapshot retries a fresh checkout" {
  "$hook"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  rm -rf "$snapshot/objects"
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'snapshot unusable'* ]]
  assert_checkout "$old"
}

@test "missing revision fails without replacing an existing checkout" {
  "$hook"
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  run "$hook"
  [ "$status" -ne 0 ]
  assert_checkout "$old"
}

@test "read-only mode never saves and refresh-only installs no worktree" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH=false
  run "$hook"
  [ "$status" -eq 0 ]
  assert_checkout "$old"
  [ "$(rg_count_saves)" -eq 0 ]
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH=true BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY=true
  run "$hook"
  [ "$status" -eq 0 ]
  [ -d "$BUILDKITE_BUILD_CHECKOUT_PATH" ]
  [ -z "$(ls -A "$BUILDKITE_BUILD_CHECKOUT_PATH")" ]
  [ "$(rg_count_saves)" -eq 1 ]
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
  "$hook"
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_TREELESS=true
  export GIT_TRACE2_EVENT="$BATS_TEST_TMPDIR/trace.json"
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.partialclonefilter)" = tree:0 ]
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'new contents' ]
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(find "$TEST_CACHE" -name .git | wc -l)" -eq 2 ]
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-list --objects --missing=print 'HEAD^{tree}'
  [ "$status" -eq 0 ]
  [[ "$output" != *'?'* ]]
  historical_tree="$(git -C "$source_repo" rev-parse "$old^{tree}")"
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" cat-file -e "$historical_tree"
  [ "$status" -ne 0 ]
  run "$hook"
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
}

@test "agent mode preserves refs and supports a plain stale delta fetch" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_MODE=agent
  git -C "$source_repo" reset --hard "$old"
  git -C "$source_repo" tag seed "$old"
  source "$hook"
  [ "$BUILDKITE_SKIP_CHECKOUT" = false ]
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" fetch origin "$old"
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" checkout -f FETCH_HEAD
  source "$BATS_TEST_DIRNAME/../hooks/post-checkout"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  [ "$(git --git-dir="$snapshot" rev-parse refs/tags/seed)" = "$old" ]
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  git -C "$source_repo" reset --hard "$latest"
  export BUILDKITE_COMMIT="$latest"
  "$hook"
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" fetch origin "$latest"
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" checkout -f FETCH_HEAD
  assert_checkout "$latest"
  expected_objects="$(git -C "$source_repo" rev-list --objects --all | wc -l)"
  packed_objects="$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" count-objects -v | sed -n 's/^in-pack: //p')"
  [ "$packed_objects" -eq "$expected_objects" ]
}

@test "default agent mode with mirrors enabled never restores or saves" {
  unset BUILDKITE_PLUGIN_GIT_SNAPSHOT_MODE
  export BUILDKITE_GIT_MIRRORS_PATH="$BATS_TEST_TMPDIR/mirrors"
  source "$hook"
  source "$BATS_TEST_DIRNAME/../hooks/post-checkout"
  [ "$BUILDKITE_SKIP_CHECKOUT" = false ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git" ]
  [ ! -e "$TEST_CACHE/operations" ]
}
