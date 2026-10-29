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
| `patches` | `true` | Restore and save per-commit patches (see below). |
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

## Patch cache: one upstream fetch per commit, not per job

A snapshot alone still leaves every job fetching its commit from origin, which
hits Git host rate limits in large organizations. So the first job to check out
a commit also saves a **patch**: a Git bundle holding what the snapshot lacks for
that commit—the newer commits and the commit's tree, filtered like the snapshot.
Later jobs for that commit restore the patch from Cache and check out without
fetching. Set `patches: false` to turn this off.

* Keys are `[key-prefix, repo, filter, snapshot commit, build commit]`, exact
  match only and write-once. A snapshot refresh changes the snapshot commit, so
  old patches simply stop matching and expire.
* Restore uses a patch only when `BUILDKITE_COMMIT` is a full SHA. A `HEAD` or
  branch build fetches as usual, then saves its patch under the commit the agent
  resolved, so the build's later jobs, pinned to that SHA, hit.
* A hit runs `git bundle verify`, unbundles, and confirms offline that every
  commit back to the snapshot and the whole build tree are present. Objects are
  content-addressed, so a bad patch can only be incomplete; that falls back to a
  fetch.
* Parallel jobs on a brand-new commit all miss and fetch; the first save wins.
* Deeper history still lazily fetches as before. Submodules and LFS are not covered.

### Let the agent skip its fetch

In `mode: agent`, the agent fetches the commit again unless
`git-skip-fetch-existing-commits` is on (agent 3.119.0+, no experiment flag).
The pre-checkout hook exports `BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS=true`
for a job whose commit is local after restore, and `false` for one whose commit
is not. That works under the default `checkout-override-mode` (`from-job`, as on
hosted agents). Under `strict`, or with command evaluation disabled, the agent
blocks the change; set it in the agent configuration instead:

```sh
BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS=true  # or git-skip-fetch-existing-commits=true
```

With the agent setting, a patch miss pays for the agent's presence check. Git
must honor `GIT_NO_LAZY_FETCH` (2.43.4+, 2.45.1+, or Ubuntu 24.04's
`2.43.0-1ubuntu7.4`); older Git lazily fetches the missing commit's whole
history. Ubuntu's Git 2.43.0 also scans every promisor object first: on hosted
agents that added about 21s (treeless) and 107s (blobless) to a Linux miss.
Git 2.45.4 and later answered immediately in a local check.

Skip-fetch does not cover branch verification. With `git-commit-verification`
`strict` (the default) or `fail-closed`, the agent still fetches the branch tip
once per job to check the commit is on the branch. It skips that for `HEAD`,
tag, pull request and custom-refspec builds, or with `git-commit-verification=off`.
`git-fetch-base-branch` (off by default) also fetches regardless. The plugin
leaves these alone. `mode: checkout` does not verify branches, and does no fetch
at all on a hit.

On Linux with hosted agents, a 1 + 8 job build dropped from 45 upstream Git
sessions (108 HTTP requests) to 13 (52) in agent mode, and from 36 (63) to 4 (7)
in checkout mode. Each agent-mode hit's one remaining session is branch
verification. [Details](benchmarks/patch-cache.md).

## Notes

* Keep Git authentication available during checkout **and the job**: both filters
  lazily fetch missing history from `origin`. Configure credentials outside the
  repo; embedded HTTP credentials are rejected and local Git config is not cached.
* Cache policies must prevent untrusted PRs from saving snapshots or patches
  trusted jobs restore. `refresh: false` (which also stops patch saves) is not an
  access policy. Never cache secrets.
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
