# Git Snapshot Buildkite Plugin

Speed up large-repository checkouts by restoring a **treeless, full-history `.git`**
from Buildkite Cache, fetching the delta, and checking out with eight workers.
Snapshots include the saved revision's trees and blobs, but not historical
trees/blobs or the worktree. Set `treeless: false` for blobless snapshots that
retain historical trees. `origin` remains a promisor remote for lazy history fetches.

```yaml
steps:
  - label: Test
    command: "./run-tests"
    plugins:
      - buildkite-playground/git-snapshot#main:
          treeless: true
          checkout-workers: 8
          max-age: 86400
```

Pin a reviewed commit instead of `main` in production. Requires Bash, Git 2.43+
and clustered Buildkite agents 4.0.3+ with Buildkite Cache configured. Hosted
agents already have a Cache store. By default, pre/post-checkout hooks seed the
repository and let the agent own checkout. Do not set `BUILDKITE_SKIP_CHECKOUT`.

## If your job uses path history, set `treeless: false`

**Treeless is the default for checkout-oriented CI. Use blobless mode for jobs
that walk historical file paths or frequently check out old revisions:**

* `git log -- <path>` and `git blame`.
* Docs last-updated features that run Git log per file: Hugo `enableGitInfo`,
  Docusaurus `showLastUpdateTime`, and MkDocs git-revision-date plugins.
* Blame-based code-owner, review and coverage tools.
* Checking out old commits or tags whose trees/blobs are not in the snapshot.

```yaml
plugins:
  - buildkite-playground/git-snapshot#main:
      treeless: false
```

Missing historical trees can cause many serial lazy fetches. In our hosted
probes, Linux `git log -n 50 -- MAINTAINERS` took **150s / 199 fetches** with
treeless versus 0.013s / zero fetches blobless. Chromium's `DEPS` path log
**timed out after more than 300s / 96 fetches**, returning only 22 of 50 commits.
These are single diagnostic samples, not predictions for every repository.
Merge-base plus `git diff --name-only` stayed comparatively cheap: about
**1–3 fetches** in the tested treeless ~50/~500-commit cases. See
[the measured costs and limitations](benchmarks/treeless.md).

Blobless avoids the missing-tree penalty, but missing historical blobs can
still require authentication and network access, including for blame and old
checkouts. Treeless and blobless use distinct Cache keys, so switching this
setting never restores the other filter's snapshot.

## Git mirrors and hosted agents

**When `BUILDKITE_GIT_MIRRORS_PATH` is nonempty, the default mode skips both
restore and save.** It logs the reason and leaves normal mirror checkout alone.
It does not inspect mirror freshness, override protected variables, or change
cluster settings. To use snapshots in default mode on hosted agents, turn off
Git mirror volumes on the cluster first; that is an administrator decision.

Hosted agent 4.7.0+15166 protects both mirror path and skip-update settings even
from plugin hooks. Our diagnostic jobs started with no mirror, rejected both
hook overrides, and created mirrors anyway. Simply restoring `.git` does not
bypass that work. An empty pipeline mirror-path setting is not an opt-out.

Several native benchmark jobs cloned fresh mirrors, but that establishes cold
mirror contents, **not** missing volume attachments or a fleet-wide miss rate.
The single 1,762s Chromium baseline was a controlled default full clone with
mirrors off, not a measurement of native mirror creation.

If mirrors cannot be disabled, explicitly opt into `mode: checkout`. This runs
the plugin-owned checkout in pre-checkout and then skips agent checkout, without
changing mirror settings. **Tradeoff:** this mode does not inherit the agent's Git
clone/fetch/clean flags, branch-membership verification, sparse checkout,
submodule or LFS orchestration. The default `mode: agent` preserves these agent
behaviors. `BUILDKITE_CLEAN_CHECKOUT=true` bypasses snapshot seeding in agent
mode, because the agent removes that directory before checkout.

## Behavior

* Restore into an empty temporary directory; a miss or restore error cannot reuse
  leftovers. No CLI log parsing is needed, and Cache is invoked with `--no-color`.
* Configure the promisor remote with `tree:0` (or `blob:none` when `treeless: false`) and
  `checkout.workers=8` and `checkout.thresholdForParallelism=1`. This downloads
  HEAD's blobs in bulk. No shallow clone or object alternates are used.
  Snapshots retain real refs, including tags, so plain agent fetch negotiates
  existing history rather than downloading it again. The stale index is dropped.
* In agent mode, an existing checkout is left alone. A cache miss or invalid
  snapshot seeds a fresh partial clone before normal agent fetch/checkout/clean.
  Cache save failure is nonfatal. Agent fetch and checkout failures retain the
  agent's normal retry/failure behavior. User-supplied depth flags are honored,
  but shallow repositories are not saved as full-history snapshots.
* In checkout mode, a failed cached fetch/checkout retries a fresh partial clone.
  Pinned commits remain pinned, including force-pushed PRs. `BUILDKITE_COMMIT=HEAD`
  resolves `BUILDKITE_REFSPEC`, GitHub's PR head/merge ref, or `BUILDKITE_BRANCH`,
  in that order. Use full commit SHAs for API-triggered checkout-mode builds;
  Git servers cannot fetch abbreviated object IDs as refs. A custom refspec is
  a **single** Git refspec, not shell arguments.
* In checkout mode the plugin **replaces everything** in the agent's dedicated checkout
  directory, including ignored files and nested repositories. Do not share it
  with other jobs or keep persistent data there. Snapshots and materialization
  temporarily need disk space outside that directory.
* Git hooks in a snapshot are not run. In checkout mode submodules are **not initialized**; run
  `git submodule update --init --recursive` yourself if needed. Submodule data is
  not cached. Git LFS downloads are not accelerated by this plugin.

## Refresh and expiration

The key is `[key-prefix, hash(BUILDKITE_REPO + newline + filter), floor(unix-time / max-age)]`.
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
first job after expiry still works, but pays for a fresh partial-clone fetch.

Snapshots retain blobs hydrated by earlier refreshes and can grow over time.
Changing `key-prefix` forces a fresh partial-clone seed if you need to discard that
accumulated data; expiration of old Cache entries alone does not shrink a newer
snapshot derived from them.

For a scheduled refresh pipeline, schedule this step daily (or more often):

```yaml
steps:
  - label: Refresh Git snapshot
    command: ":"
    plugins:
      - buildkite-playground/git-snapshot#main:
          refresh-only: true
```

`refresh-only` still fetches and materializes HEAD to hydrate its blobs before
saving. Agent mode retains the normal agent worktree; checkout mode materializes
it in temporary storage and installs no worktree. It does **not** suppress the
step's command: use `command: ":"`. Use the same repo URL, key
prefix, max-age, cluster/registry, and compatible Cache policy as consumer jobs.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `mode` | `agent` | Pre/post-checkout with mirror bypass; `checkout` opts into plugin-owned checkout. |
| `treeless` | `true` | Use `tree:0`; set `false` for blobless (`blob:none`) path-history jobs. |
| `checkout-workers` | `8` | Positive number of parallel checkout workers. |
| `max-age` | `86400` | Refresh age and key period in seconds, 1–86400. |
| `refresh` | `true` | Save on misses or stale restores. `false` is read-only Cache use. |
| `refresh-only` | `false` | Refresh job; use a no-op command. Checkout mode installs no worktree. |
| `key-prefix` | `git-snapshot-v3` | Namespace/version; change to invalidate snapshots. |

## Authentication and trust

Git authentication must be available **during checkout and during the job**.
History-walking commands such as `blame` and `log -p` can lazily download many
historical blobs and may be slower than a full clone. Keep `origin` reachable;
do not remove its promisor configuration. Configure SSH or a credential helper
outside the repo, for example in an agent environment/pre-checkout hook. URLs
with embedded HTTP credentials are rejected so tokens cannot enter snapshots.
Repository-local Git config is regenerated on restore; do not rely on local
credential helpers or custom filters being copied. Treeless mode additionally
omits historical trees: name-only diffs and path-limited logs can need many
network round trips. `fetch.recurseSubmodules=false` prevents fetch-time tree
walking; the agent still controls explicit submodule checkout in agent mode.

**Caches are trusted Git metadata, not a security boundary.** Configure Cache
registry policies so untrusted PR jobs cannot save snapshots trusted builds
restore. `refresh: false` is useful for consumers, but is not an access policy.
Registry scopes may prevent sharing across pipelines or branches even when keys
match. Do not cache secrets. This plugin does not use cache volumes or change
cluster settings.

## Hosted measurements

Controlled agent-owned pre/post checkouts on Chromium (512,501 tracked entries,
1,853,106 commits), with mirrors off:

| Snapshot | Archive | Warm n | Median | p90 |
| --- | ---: | ---: | ---: | ---: |
| Treeless, default | 2.56 GB | 10 | 32.85s | 35.85s |
| Blobless, opt-out | 6.27 GB | 10 | 57.18s | 60.27s |

Each filter had three sequential and seven concurrent samples. Times include
plugin setup, restore, agent fetches and checkout, but not correctness checks.
These are small, workload-specific samples, not native mirrors-on hosted times.
**Treeless history is costly:** `git log -n 50 -- DEPS` timed out after 300s and
96 lazy fetches, returning only 22 commits; blobless returned all 50 in 0.021s.
See [the comparison, history probes and limitations](benchmarks/treeless.md).

### Earlier plugin-owned checkout

On the same Chromium revision, 11 warm snapshots had a **65.7s median / 68.3s
p90**, including plugin setup,
restore, fetch and checkout. Eight samples overlapped on separate hosted-large
agents. Single default-clone/blobless-clone baselines were 1762.3s/715.6s;
these are practical checkout strategies, not equal-object transfer comparisons.
The snapshot archive was 5.77 GB. A newer revision restored, fetched its delta
and checked out in approximately 77.83s, plus 51.68s for the refresh save
(129.51s total, one sample; decomposition from timestamped logs).

See [methodology, raw samples and limitations](benchmarks/README.md) before using
these numbers. In particular, controlled comparisons disable mirrors; the real
hosted-job check with protected mirror settings unchanged is reported separately.

## Development

```sh
docker compose run --rm tests
docker compose run --rm lint
docker compose run --rm shellcheck
```

Or install Bats, Git and ShellCheck locally and run `bats tests/` and
`shellcheck hooks/* lib/*.sh tests/cache-agent`. Tests use real Git repositories
and a filesystem Cache stand-in, never repository code or a live Cache store.
