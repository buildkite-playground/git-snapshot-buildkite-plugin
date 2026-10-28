# Git Snapshot Buildkite Plugin

Speed up large-repository checkouts by restoring a **blobless, full-history `.git`**
from Buildkite Cache. The **agent still owns checkout**: fetch, commit verification,
forced checkout, clean, PR refspecs, sparse checkout, submodules, and LFS.
Snapshots include the saved revision's Git blobs, but not historical blobs or the
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
agents already have a Cache store. No cache volumes are used.

## How it works

* **Pre-checkout:** if `.git` already exists, leave it to the agent. Otherwise,
  restore into a private temporary directory. A miss, restore error, or invalid
  snapshot creates an empty blobless repository for the agent to fetch into.
  The checkout directory's other files are not removed by the plugin.
* Rebuild local config with canonical `origin`, `remote.origin.promisor=true`,
  `remote.origin.partialclonefilter=blob:none`, `checkout.workers=8`, and
  `checkout.thresholdForParallelism=1`. Plain agent fetches therefore remain
  blobless, unless explicitly overridden by user fetch flags. A real local
  `refs/heads/buildkite-snapshot` ref advertises saved history during ordinary
  Git negotiation, including when the checkout later detaches HEAD.
* Drop the restored index: even an unchanged commit must write its full tree.
  The agent sees an existing repository, reconciles its remote URL, fetches,
  verifies the commit, checks out, and cleans using its normal flags and retries.
  If agent checkout fails, the agent's normal retry/fresh-clone policy applies;
  that fallback may be a full clone rather than blobless.
* **Post-checkout:** opportunistically save on a miss or stale snapshot. Build
  a separate `.git` from root Git objects and fresh configuration/ref metadata.
  Never copy the worktree, index, credentials, hooks, sparse settings, LFS objects,
  or `.git/modules`. Snapshot preparation/save failures are nonfatal.
* Only independent, non-shallow blobless repositories are saved. Alternate-
  dependent reference clones, ordinary full clones, and shallow clones are skipped.

## Agent settings and limits

The plugin has no `checkout` hook and does not replace the agent's Git commands
or rewrite checkout environment settings. `BUILDKITE_COMMIT=HEAD`, pinned commits,
GitHub PR head/merge refspecs, custom `BUILDKITE_REFSPEC`, fetch/checkout/clean flags,
commit verification, sparse checkout, submodules, and LFS remain agent-owned.
Submodule and LFS transfers are **not** accelerated or cached. Sparse snapshots
only hydrate the selected files; a later full checkout may need more blobs.

Clone-only flags (including `--depth` in `BUILDKITE_GIT_CLONE_FLAGS`) naturally
do not run when a snapshot makes the repository already exist. Fetch depth flags
still apply, but resulting shallow checkouts are not saved. Do not combine this
full-history optimization with a requirement for clone-only semantics.

`BUILDKITE_CLEAN_CHECKOUT=true` deletes the checkout **after** pre-checkout, so
the plugin skips restoring/initializing and allows the agent's clean clone.
`BUILDKITE_SKIP_CHECKOUT=true` similarly bypasses the plugin. Neither is a way
to request an accelerated fresh restore. Existing checkouts retain their own
configuration, including checkout worker settings; plugin settings apply to
newly initialized/restored directories.

**On-host Git mirrors are separate work.** The agent updates them even when
the checkout already contains restored `.git`. A cold full mirror can dominate
time and disk use; the plugin does not silently disable it. For Cache-only
checkout on fresh hosted agents, set `BUILDKITE_GIT_MIRRORS_SKIP_UPDATE: "true"`
in a trusted agent/plugin hook; when no mirror exists the agent proceeds
without one. Pipeline environment values cannot override this protected setting.
On self-hosted agents, disable `git-mirrors-path` in agent config if mirrors are
unwanted. That path is agent-only: an empty job environment value does not
override it. Skip-update can still reuse an existing mirror.
If mirrors stay enabled, agent `dissociate` behavior is retained; `reference`
mode can add alternates and prevents saving an independent snapshot. Remote
mirror/clone fallback configuration likewise remains under agent control.

Do not combine this plugin with another custom checkout hook. Give every job a
dedicated checkout directory. Refresh jobs temporarily need another copy of the
root Git object database plus space for Cache archive creation; warm restores
need the extracted `.git`, worktree, and download/extraction headroom.

## Refresh and expiration

The key is `[key-prefix, hash(BUILDKITE_REPO), floor(unix-time / max-age)]`.
`fallback_limit` is on the repository hash, making only the period optional.
An exact hit wins; otherwise Cache selects the newest matching period. The
relative target `.git` is the only archived path. Different URL spellings
intentionally have different keys. Cache CLI calls use `--no-color`; output
is not parsed to detect hits.

After checkout, a miss or snapshot at least `max-age` seconds old is saved under
the current period, without `--force`. Concurrent jobs can race to populate the
same immutable key; an existing entry is left intact. Creation time is stored
inside `.git`, not inferred from CLI output or filesystem timestamps.

Cache entries expire three days after creation or their last **exact** restore.
Fallback restores do not extend that lifetime. The default refresh/key period
is one day; `max-age` may be shortened but cannot exceed one day. Keep a trusted
job running daily to avoid idle expiry. The first job after expiry still works,
but pays for a fresh blobless fetch.

For a scheduled refresh pipeline, schedule this step daily (or more often):

```yaml
steps:
  - label: Refresh Git snapshot
    command: ":"
    plugins:
      - buildkite-playground/git-snapshot#main:
          refresh-only: true
```

`refresh-only` identifies a scheduled refresh job. It follows the same age policy
and **still lets the agent install a worktree**, hydrating the selected revision's
blobs before saving. It does not suppress the command: use `command: ":"`.
Use the same repository URL, key prefix, max-age, cluster/registry, and compatible
Cache policy as consumer jobs. Unlike the original checkout-hook implementation,
refresh-only does not remove/withhold the agent's worktree.

## Options

| Option | Default | Meaning |
| --- | --- | --- |
| `checkout-workers` | `8` | Positive number of parallel checkout workers. |
| `max-age` | `86400` | Refresh age and key period in seconds, 1–86400. |
| `refresh` | `true` | Save on misses or stale restores. `false` is read-only Cache use. |
| `refresh-only` | `false` | Mark a scheduled refresh job; pair with `command: ":"`. |
| `key-prefix` | `git-snapshot-v2` | Namespace/version; change to invalidate snapshots. |

## Authentication and trust

Git authentication must be available **during checkout and during the job**.
History-walking commands such as `blame` and `log -p` can lazily download many
historical blobs and may be slower than a full clone. Keep `origin` reachable;
do not remove its promisor configuration. Configure SSH or a credential helper
outside the repository. URLs with embedded HTTP credentials are rejected so
tokens cannot enter snapshots. Agent-local auth/config is not copied into Cache.

**Caches are trusted Git metadata, not a security boundary.** Configure registry
policies so untrusted PR jobs cannot save snapshots trusted builds restore.
`refresh: false` is useful for consumers but is not an access policy. Registry
scopes may prevent sharing across pipelines or branches even when keys match.
Do not cache secrets. The plugin does not change cluster settings.

## Development

```sh
docker compose run --rm tests
docker compose run --rm lint
docker compose run --rm shellcheck
```

Or run `bats tests/` and
`shellcheck -x hooks/pre-checkout hooks/post-checkout lib/snapshot.sh tests/cache-agent`
locally. Tests use real Git and a filesystem Cache stand-in. They include plain
agent-style fetch negotiation from a stale snapshot; hosted validation uses the
real agent. No checked-out repository code is executed by the tests.
