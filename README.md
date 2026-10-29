# Git Snapshot Buildkite Plugin

Speed up large-repository checkouts by restoring a treeless, full-history `.git`
from Buildkite Cache, fetching changes and checking out with eight parallel
workers. Only Git metadata is cached, never the worktree.

![Checkout without vs with Git Snapshot: Chromium 29m 22s vs 33s; Linux 4m 17s vs 11s](benchmarks/checkout-times.svg)

Warm snapshots on hosted-large, mirrors off; seeding and refresh cost extra.
Chromium: full clone n=1 vs plugin median n=10. Linux: custom baseline median n=4
vs plugin median n=3, with different revisions/timing scopes—not a matched comparison.
[Methodology and sources](benchmarks/treeless.md#with-and-without-plugin-comparison).

## Example

```yaml
steps:
  - command: "./run-tests"
    plugins:
      - buildkite-playground/git-snapshot#main: {}
```

Requires Bash, Git 2.43+ and clustered agents 4.0.3+ with Buildkite Cache configured
(included on hosted agents). Pin a reviewed commit in production. The agent owns
checkout through pre/post-checkout hooks; do not set `BUILDKITE_SKIP_CHECKOUT`.

## If your job uses path history, set `treeless: false`

Treeless is best for checkout-only CI. Use blobless mode for:

* `git log -- <path>` and `git blame`.
* Docs last-updated features: Hugo `enableGitInfo`, Docusaurus
  `showLastUpdateTime`, and MkDocs git-revision-date plugins.
* Blame-based code-owner, review and coverage tools.
* Checking out old commits or tags.

```yaml
plugins:
  - buildkite-playground/git-snapshot#main:
      treeless: false
```

Missing trees can trigger many lazy fetches: Linux's `MAINTAINERS` path log took
**150s / 199 fetches**; Chromium's `DEPS` log **timed out after >300s**.
Merge-base plus `diff --name-only` stayed cheap at about **1–3 fetches** in these
single-sample probes. [Details](benchmarks/treeless.md#lazy-history-operations).

## Git mirrors

**With Git mirrors enabled (`BUILDKITE_GIT_MIRRORS_PATH` nonempty), the default
mode skips both restore and save.** To use snapshots on hosted agents, disable
Git mirror volumes on the cluster, or opt into `mode: checkout` below. The plugin
does not change protected mirror settings or use cache volumes.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `treeless` | `true` | Use `tree:0`; set `false` for blobless (`blob:none`) path-history jobs. |
| `checkout-workers` | `8` | Number of parallel checkout workers. |
| `mode` | `agent` | Agent-owned checkout; `checkout` replaces it (see below). |
| `max-age` | `86400` | Refresh age and key period in seconds, 1–86400. |
| `refresh` | `true` | Save missing or stale snapshots. `false` makes Cache use read-only. |
| `refresh-only` | `false` | Refresh job; pair with `command: ":"`. |
| `key-prefix` | `git-snapshot-v3` | Cache namespace; change to re-seed snapshots. |

`mode: checkout` works without disabling mirrors, but does not inherit the
agent's clone/fetch/clean flags, branch verification, sparse checkout, submodules
or LFS handling. It replaces everything in the dedicated checkout directory,
including ignored files. Use full commit SHAs for API-triggered builds.

## Refreshing snapshots

Misses fetch a fresh partial clone. Old snapshots refresh after checkout under
write-once period keys. Keys include the repo URL and filter, so treeless and
blobless snapshots never mix. Save failures do not fail a usable checkout.

Cache entries expire three days after creation or their last exact restore;
fallback restores do not extend this. Run a trusted job daily, or schedule:

```yaml
steps:
  - command: ":"
    plugins:
      - buildkite-playground/git-snapshot#main:
          refresh-only: true
```

Use the same repo URL, key settings and Cache scope as consumer jobs.
`refresh-only` still materializes HEAD; it does not skip the command.

## Notes

* Keep Git authentication available during checkout **and the job**: both filters
  lazily fetch missing history from `origin`. Configure credentials outside the
  repo; embedded HTTP credentials are rejected and local Git config is not cached.
* Cache policies must prevent untrusted PRs from saving snapshots trusted jobs
  restore. `refresh: false` is not an access policy. Never cache secrets.
* Agent mode leaves existing checkouts alone; `BUILDKITE_CLEAN_CHECKOUT=true`
  bypasses seeding. Shallow or mirror-dependent checkouts are not saved.
* Submodule data and LFS downloads are not cached. In checkout mode, initialize
  submodules yourself with `git submodule update --init --recursive`.

## Development

```sh
docker compose run --rm tests
docker compose run --rm lint
docker compose run --rm shellcheck
```
