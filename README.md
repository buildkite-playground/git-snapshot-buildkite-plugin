# Git Snapshot Buildkite Plugin

Speed up large-repository checkouts by restoring a treeless, full-history `.git`
from Buildkite Cache before the agent checks out. The agent then fetches only new
commits, or nothing when a per-commit patch is cached, and checks out with eight
parallel workers. The plugin never performs the checkout itself. Only Git
metadata is cached, never the worktree.

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

## How this works

![Animated diagram of one job. pre-checkout restores the snapshot and the commit's patch from Buildkite Cache. On a hit, the agent's checkout skips its fetch, so only its branch check reaches upstream. After a miss, post-checkout saves the patch, and about once a day it saves a new snapshot.](docs/how-it-works.svg)

The plugin keeps two kinds of entries in Buildkite Cache:

* **Snapshot**: the big one, the repository's whole `.git` with full history
  (treeless by default; about 1 GB for Linux). It is saved about once per
  `max-age` period, which is daily by default.
* **Patch**: a small Git bundle from the snapshot's commit to one build commit
  (about 0.5 MB for Linux). It is saved once per new commit, usually by the
  first job that builds it.

| Step | Runs in | When |
| --- | --- | --- |
| Restore the snapshot | pre-checkout | Every job; on a Cache miss it clones from upstream instead |
| Look up and apply the commit's patch | pre-checkout | Every job whose `BUILDKITE_COMMIT` is a full SHA other than the snapshot's |
| Tell the agent to skip its fetch | pre-checkout | When the commit is local after the restore ([details](#let-the-agent-skip-its-fetch)) |
| Fetch the commit | agent checkout | Only when the commit is not local, such as after a patch miss |
| Check the commit is on the branch | agent checkout | Branch builds unless `git-commit-verification=off`; a hit's only upstream request |
| Check out the commit | agent checkout | Every job |
| Save the patch | post-checkout | After a patch miss or a `HEAD` build: usually the first job on a new commit |
| Save a new snapshot | post-checkout | When the restored snapshot is older than `max-age`: about once a day |

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

**With Git mirrors enabled (`BUILDKITE_GIT_MIRRORS_PATH` nonempty), the plugin
skips both restore and save**, and the agent checks out as usual. To use
snapshots on hosted agents, disable Git mirror volumes on the cluster. The plugin
does not change protected mirror settings or use cache volumes.

## Options

| Option | Default | Description |
| --- | --- | --- |
| `treeless` | `true` | Use `tree:0`; set `false` for blobless (`blob:none`) path-history jobs. |
| `checkout-workers` | `8` | Number of parallel checkout workers. |
| `max-age` | `86400` | Refresh age and key period in seconds, 1–86400. |
| `refresh` | `true` | Save missing or stale snapshots. `false` makes Cache use read-only. |
| `refresh-only` | `false` | Scheduled refresh job; pair with `command: ":"` (see below). |
| `patches` | `true` | Restore and save per-commit patches (see below). |
| `key-prefix` | `git-snapshot-v3` | Cache namespace; change to re-seed snapshots. |

The `mode` option has been removed: the agent always performs the checkout. A
leftover `mode` setting only logs a warning.

## Refreshing snapshots

Misses fetch a fresh partial clone. Old snapshots refresh after checkout under
write-once period keys. Keys include the repo URL and filter, so treeless and
blobless snapshots never mix. Save failures do not fail a usable checkout.

Cache entries expire three days after creation or their last exact restore;
fallback restores do not extend this. A job refreshes a snapshot once it is
`max-age` old. To refresh on a schedule, run a trusted job daily with
`refresh-only`:

```yaml
steps:
  - command: ":"
    plugins:
      - buildkite-playground/git-snapshot#main:
          refresh-only: true
```

A `refresh-only` job also refreshes a snapshot saved in an earlier key period
(a UTC day with the default `max-age`), so a daily schedule saves every day even
when the last run was a few minutes less than a day ago. The agent still checks
out the build's commit, and the command still runs. Use the same repo URL, key
settings and Cache scope as consumer jobs.

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

The agent fetches the commit again unless
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
leaves these alone.

On Linux with hosted agents, a 1 + 8 job build dropped from 45 upstream Git
sessions (108 HTTP requests) to 13 (52). Each hit's one remaining session is
branch verification; hits with verification off made none.
[Details](benchmarks/patch-cache.md).

## Notes

* Keep Git authentication available during checkout **and the job**: both filters
  lazily fetch missing history from `origin`. Configure credentials outside the
  repo; embedded HTTP credentials are rejected and local Git config is not cached.
* Cache policies must prevent untrusted PRs from saving snapshots or patches
  trusted jobs restore. `refresh: false` (which also stops patch saves) is not an
  access policy. Never cache secrets.
* The plugin leaves existing checkouts alone; `BUILDKITE_CLEAN_CHECKOUT=true`
  bypasses seeding. Shallow or mirror-dependent checkouts are not saved.
* Submodule data and LFS downloads are not cached.

## Development

```sh
docker compose run --rm tests
docker compose run --rm lint
docker compose run --rm shellcheck
```
