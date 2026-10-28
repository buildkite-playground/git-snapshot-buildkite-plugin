# Git Snapshot Buildkite Plugin

Speed up large-repository checkouts by restoring a **blobless, full-history `.git`**
from Buildkite Cache, fetching the delta, and checking out with eight workers.
Snapshots include the saved revision's blobs, but not historical blobs or the
worktree. `origin` remains a promisor remote for lazy history fetches.

```yaml
steps:
  - label: Test
    command: "./run-tests"
    plugins:
      - buildkite-playground/git-snapshot#main:
          checkout-workers: 8
          max-age: 86400
```

Pin a reviewed commit instead of `main` in production. Requires Bash, Git 2.43+
and clustered Buildkite agents 4.0.3+ with Buildkite Cache configured. Hosted
agents already have a Cache store. This replaces the agent's checkout, not its
plugin download. Do not set `BUILDKITE_SKIP_CHECKOUT`.

## Behavior

* Restore into an empty temporary directory; a miss or restore error cannot reuse
  leftovers. No CLI log parsing is needed, and Cache is invoked with `--no-color`.
* Fetch with `--filter=blob:none`, then detached checkout with
  `checkout.workers=8` and `checkout.thresholdForParallelism=1`. This downloads
  HEAD's blobs in bulk. No shallow clone or object alternates are used.
* A corrupt snapshot or failed cached fetch/checkout retries from a fresh
  blobless repository. Cache save failure is nonfatal. If the fresh fetch or
  checkout also fails (for example, invalid revision or missing auth), the job
  fails rather than running at the wrong revision.
* Pinned commits remain pinned, including force-pushed PRs. `BUILDKITE_COMMIT=HEAD`
  resolves `BUILDKITE_REFSPEC`, GitHub's PR head/merge ref, or `BUILDKITE_BRANCH`,
  in that order. A custom refspec is a **single** Git refspec, not shell arguments.
* On success the plugin **replaces everything** in the agent's dedicated checkout
  directory, including ignored files and nested repositories. Do not share it
  with other jobs or keep persistent data there. Snapshots and materialization
  temporarily need disk space outside that directory.
* Git hooks in a snapshot are not run. Submodules are **not initialized**; run
  `git submodule update --init --recursive` yourself if needed. Submodule data is
  not cached. Git LFS downloads are not accelerated by this plugin.

## Refresh and expiration

The key is `[key-prefix, hash(BUILDKITE_REPO), floor(unix-time / max-age)]`.
`fallback_limit` is on the repository hash, making only the period optional.
An exact hit wins; otherwise Cache selects the newest matching period. The
relative target `.git` is identical across jobs and is the only archived path.
Different URL spellings intentionally have different keys.

After checkout, a miss or a snapshot at least `max-age` seconds old is saved
under the current period, without `--force`. Concurrent jobs may try to populate
the same period; entries are write-once and an existing entry is left intact.
Creation time is stored inside `.git`, not inferred from colored log output or
filesystem timestamps. A save never contains worktree files.

Cache entries expire three days after creation or their last **exact** restore.
Fallback restores do not extend that lifetime. The default refresh age and key
period are one day; `max-age` may be shortened but cannot exceed one day. Keep
at least one trusted job running daily if you want to avoid idle expiry. The
first job after expiry still works, but pays for a fresh blobless fetch.

For a scheduled refresh pipeline, schedule this step daily (or more often):

```yaml
steps:
  - label: Refresh Git snapshot
    command: ":"
    plugins:
      - buildkite-playground/git-snapshot#main:
          refresh-only: true
```

`refresh-only` still fetches and materializes HEAD in temporary storage, to
hydrate its blobs before saving, but installs no worktree. It does **not**
suppress the step's command: use `command: ":"`. Use the same repo URL, key
prefix, max-age, cluster/registry, and compatible Cache policy as consumer jobs.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `checkout-workers` | `8` | Positive number of parallel checkout workers. |
| `max-age` | `86400` | Refresh age and key period in seconds, 1–86400. |
| `refresh` | `true` | Save on misses or stale restores. `false` is read-only Cache use. |
| `refresh-only` | `false` | Populate snapshots without installing a worktree. |
| `key-prefix` | `git-snapshot-v1` | Namespace/version; change to invalidate snapshots. |

## Authentication and trust

Git authentication must be available **during checkout and during the job**.
History-walking commands such as `blame` and `log -p` can lazily download many
historical blobs and may be slower than a full clone. Keep `origin` reachable;
do not remove its promisor configuration. Configure SSH or a credential helper
outside the repo, for example in an agent environment/pre-checkout hook. URLs
with embedded HTTP credentials are rejected so tokens cannot enter snapshots.
Repository-local Git config is regenerated on restore; do not rely on local
credential helpers, custom filters or other agent checkout options being copied.

**Caches are trusted Git metadata, not a security boundary.** Configure Cache
registry policies so untrusted PR jobs cannot save snapshots trusted builds
restore. `refresh: false` is useful for consumers, but is not an access policy.
Registry scopes may prevent sharing across pipelines or branches even when keys
match. Do not cache secrets. This plugin does not use cache volumes or change
cluster settings.

## Development

```sh
docker compose run --rm tests
docker compose run --rm lint
docker compose run --rm shellcheck
```

Or install Bats, Git and ShellCheck locally and run `bats tests/` and
`shellcheck hooks/checkout tests/cache-agent`. Tests use real Git repositories
and a filesystem Cache stand-in, never repository code or a live Cache store.
