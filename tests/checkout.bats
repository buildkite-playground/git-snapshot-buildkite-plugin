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
  pre="$BATS_TEST_DIRNAME/../hooks/pre-checkout"
  post="$BATS_TEST_DIRNAME/../hooks/post-checkout"
}

# Real Git, with the agent's default existing-repository command sequence.
# Hosted tests exercise the actual agent, including PRs, sparse and verification.
agent_checkout() {
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" clean -ffxdq || return
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" fetch -v --prune origin "${BUILDKITE_REFSPEC:-$BUILDKITE_COMMIT}" || return
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" checkout -f FETCH_HEAD || return
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" clean -ffxdq
}

checkout_job() {
  local initial_dir="$PWD"
  # The agent sources hooks and imports their environment/working-directory diff.
  source "$pre" || return
  [ "$PWD" = "$initial_dir" ] || return
  agent_checkout || return
  source "$post" || return
  [ "$PWD" = "$initial_dir" ]
}

assert_checkout() {
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse HEAD)" = "$1" ]
  [ -z "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" status --porcelain)" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.promisor)" = true ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config remote.origin.partialclonefilter)" = blob:none ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/objects/info/alternates" ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" rev-parse --is-shallow-repository)" = false ]
}

count_saves() {
  grep -c '^save ' "$TEST_CACHE/operations" || true
}

@test "cold miss saves metadata only, HEAD blobs are local, history stays lazy" {
  export BUILDKITE_COMMIT="$latest"
  run checkout_job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  assert_checkout "$latest"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  [ ! -e "$snapshot/../file" ]
  [ ! -e "$snapshot/index" ]
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" \
    rev-list --objects --missing=print "$latest^{tree}"
  [ "$status" -eq 0 ]
  [[ "$output" != *'?'* ]]
  historical_blob="$(git -C "$source_repo" rev-parse "$old:file")"
  run env GIT_ALLOW_PROTOCOL= git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" \
    rev-list --objects --missing=print "$old^{tree}"
  [ "$status" -eq 0 ]
  [[ "$output" == *"?$historical_blob"* ]]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" show "$old:file")" = 'old contents' ]
}

@test "warm restore drops stale index and materializes the entire unchanged tree" {
  checkout_job
  snapshot="$(find "$TEST_CACHE" -name .git)"
  cp "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/index" "$snapshot/index"
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  run checkout_job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  assert_checkout "$old"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = 'old contents' ]
  [ "$(count_saves)" -eq 1 ]
}

@test "existing checkout is untouched by pre-hook and cleaned by agent commands" {
  checkout_job
  printf 'dirty\n' > "$BUILDKITE_BUILD_CHECKOUT_PATH/file"
  mkdir -p "$BUILDKITE_BUILD_CHECKOUT_PATH/nested/.git"
  touch "$BUILDKITE_BUILD_CHECKOUT_PATH/.ignored"
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config checkout.workers 3
  "$pre"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/file")" = dirty ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config checkout.workers)" = 3 ]
  agent_checkout
  assert_checkout "$old"
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/nested" ]
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.ignored" ]
}

@test "plain agent fetch from a stale snapshot transfers only the delta" {
  checkout_job
  snapshot="$(find "$TEST_CACHE" -name .git)"
  period_dir="$(dirname "$snapshot")"
  period="$(basename "$period_dir")"
  echo "$(( $(date +%s) - 90000 ))" > "$snapshot/git-snapshot-created-at"
  mv "$period_dir" "$(dirname "$period_dir")/$((period - 1))"
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  export BUILDKITE_COMMIT="$latest"
  run checkout_job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=true'* ]]
  assert_checkout "$latest"
  [ "$(cat "$BUILDKITE_BUILD_CHECKOUT_PATH/added")" = 'second file' ]
  [ "$(count_saves)" -eq 2 ]
  expected_objects="$(git -C "$source_repo" rev-list --objects --all | wc -l)"
  packed_objects="$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" count-objects -v | sed -n 's/^in-pack: //p')"
  [ "$packed_objects" -eq "$expected_objects" ]
}

@test "agent branch HEAD and PR refspec fetches still work" {
  export BUILDKITE_COMMIT=HEAD
  run checkout_job
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
  rm -rf "$BUILDKITE_BUILD_CHECKOUT_PATH"
  export BUILDKITE_REFSPEC=refs/pull/7/head
  run checkout_job
  [ "$status" -eq 0 ]
  assert_checkout "$latest"
}

@test "restore/save errors and broken snapshots permit a fresh agent checkout" {
  export TEST_RESTORE_ERROR=true TEST_SAVE_ERROR=true
  run checkout_job
  [ "$status" -eq 0 ]
  [[ "$output" == *'cache save failed'* ]]
  assert_checkout "$old"
  unset TEST_RESTORE_ERROR TEST_SAVE_ERROR
  "$post"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  rm -rf "$snapshot/objects" "$BUILDKITE_BUILD_CHECKOUT_PATH"
  run checkout_job
  [ "$status" -eq 0 ]
  [[ "$output" == *'restore hit=false'* ]]
  assert_checkout "$old"
}

@test "missing revision fails instead of publishing the wrong snapshot" {
  export BUILDKITE_COMMIT=1111111111111111111111111111111111111111
  run checkout_job
  [ "$status" -ne 0 ]
  [ "$(count_saves)" -eq 0 ]
}

@test "read-only never saves; refresh-only keeps the agent-owned checkout" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH=false
  run checkout_job
  [ "$status" -eq 0 ]
  assert_checkout "$old"
  [ "$(count_saves)" -eq 0 ]
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH=true BUILDKITE_PLUGIN_GIT_SNAPSHOT_REFRESH_ONLY=true
  "$post"
  assert_checkout "$old"
  [ "$(count_saves)" -eq 1 ]
}

@test "snapshot strips local auth, hooks, sparse, LFS and submodule state" {
  "$pre"
  agent_checkout
  git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config credential.helper private-secret
  mkdir -p "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/"{hooks,modules,lfs,info}
  touch "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/hooks/post-checkout"
  echo file > "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/info/sparse-checkout"
  "$post"
  snapshot="$(find "$TEST_CACHE" -name .git)"
  [ ! -e "$snapshot/hooks/post-checkout" ]
  [ ! -e "$snapshot/modules" ]
  [ ! -e "$snapshot/lfs" ]
  [ ! -e "$snapshot/info/sparse-checkout" ]
  run git --git-dir="$snapshot" config credential.helper
  [ "$status" -ne 0 ]
  [ "$(git -C "$BUILDKITE_BUILD_CHECKOUT_PATH" config credential.helper)" = private-secret ]
}

@test "clean checkout is respected; shallow and alternate-dependent clones are never saved" {
  export BUILDKITE_CLEAN_CHECKOUT=true
  "$pre"
  [ ! -e "$BUILDKITE_BUILD_CHECKOUT_PATH/.git" ]
  unset BUILDKITE_CLEAN_CHECKOUT
  "$pre"
  agent_checkout
  echo "$old" > "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/shallow"
  "$post"
  [ "$(count_saves)" -eq 0 ]
  rm "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/shallow"
  echo "$source_repo/.git/objects" > "$BUILDKITE_BUILD_CHECKOUT_PATH/.git/objects/info/alternates"
  "$post"
  [ "$(count_saves)" -eq 0 ]
}

@test "rejects invalid config, unsafe paths and embedded HTTP credentials" {
  export BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE=86401
  run "$pre"
  [ "$status" -ne 0 ]
  unset BUILDKITE_PLUGIN_GIT_SNAPSHOT_MAX_AGE
  export BUILDKITE_BUILD_CHECKOUT_PATH=/
  run "$pre"
  [ "$status" -ne 0 ]
  export BUILDKITE_BUILD_CHECKOUT_PATH="$BATS_TEST_TMPDIR/checkout"
  export BUILDKITE_REPO=https://secret@example.com/repo.git
  run "$pre"
  [ "$status" -ne 0 ]
  [[ "$output" != *secret* ]]
}
