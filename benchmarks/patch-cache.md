# Patch cache: upstream Git requests per build — 2026-10-29

With the patch cache, a Linux build of one job plus eight parallel jobs on a commit
newer than the snapshot made **13 upstream Git sessions (52 HTTP requests)
instead of 45 (108)**. Each patch hit still makes one session: the agent's
branch verification fetch. With verification off, a hit made none. Checkout time
did not get worse. All 79 measured jobs passed correctness checks.

Rows labelled "checkout mode" measured the plugin's `mode: checkout`, which
performed the checkout itself. That mode was removed after this report; the agent
now always checks out. Those rows are kept as history only.

## Method

Each job runs one controlled `buildkite-agent bootstrap --phases=plugin,checkout`
with [patch.py](patch.py), as in the earlier rounds. Environment: Open Source
cluster, `hosted-large`, agent 4.7.0+15166.413a004b6a7aa607fa718fe2f64cc960c42d4419,
Git 2.43.0 (`1:2.43.0-1ubuntu7.4`, honors `GIT_NO_LAZY_FETCH`),
`checkout-override-mode` `from-job`. Mirrors are off, commit verification is strict
unless noted, fetch flags are `-v --prune`, and there are no submodules or LFS.
No target repository code was run, no cache volumes were declared, and no
cluster settings were changed.

How requests are counted: every Git process the agent and plugin start inherits
`GIT_TRACE_CURL` and `GIT_TRACE2_EVENT`. **HTTP requests** counts `GET`/`POST`
lines to `/torvalds/linux`. **Sessions** counts `remote-curl` processes for the
repository, sorted by parent command into the agent or plugin fetch (`fetch`),
branch verification (`verify`), and lazy fetches during checkout (`lazy`). The
agent's own fetches are included.

Checkout time runs from bootstrap start to the post-checkout hook in agent mode.
In the removed checkout mode it was the bootstrap time minus the plugin's save
interval.
Patch and snapshot saves are excluded and reported separately. Snapshot restore,
patch restore and apply, and the agent's checkout phase come from timestamped log
lines.

Commits (torvalds/linux `master`). Trees were pinned from the GitHub API:

| Name | Commit | Commits ahead of S |
| --- | --- | ---: |
| S, snapshot | `65ba8f34ec886ec72b2c07ddc8cf3d815c32869d` | 0 |
| T1 | `0ddbc782c0bb86c902eda146677087a6bfc398ee` | 79 |
| T5 | `1cb6cfab0916d18f88d44e4a23806b6c4cb355f8` | 171 |
| T2 | `e191b05f321b064a973399b7cdc003c0de89e5b9` | 287 |
| T3 | `ae3690eb2a994dd74a43639d6bf800b51f18b48c` | 437 |
| T4 | `d738fbd1a8b9d82ef5ea0d54a9e2b3ab7f1c24dd` | 439 |
| HEAD at run time | `c339f4010dea8b0d754f84ace70cd1b089878ef8` | 679 |

"Before" uses the previous plugin,
[`0637cc3`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/0637cc3dc15565c9ca5d25977f1895baa27c03be),
read-only against the same snapshot.

## Upstream requests per 1 + 8 job build

Treeless snapshots. The first job runs, then eight run in parallel.

| Build | Jobs | Sessions | HTTP requests |
| --- | --- | ---: | ---: |
| Before, agent mode @T1 | 9 × (fetch, verify, 3 lazy) | 45 | 108 |
| After, agent mode @T1 | 1 miss (5 sessions, 12 HTTP) + 8 hits (1, 5 each) | **13** | **52** |
| After, agent mode, verification off | 1 miss + 8 hits (0 each)¹ | 5 | 12 |
| Before, checkout mode (removed) @T1 | 9 × (fetch, 3 lazy) | 36 | 63 |
| After, checkout mode (removed) @T2 | 1 miss (4, 7) + 8 hits (0 each) | 4 | 7 |
| After, agent mode, HEAD first job | 1 HEAD job (4, 7) + 8 hits (1, 4 each) | 12 | 39 |

¹ Projected from measured jobs: two verification-off hits (builds 43 and 44)
made 0 requests. A whole verification-off wave was not run.

A patch hit also removes the three lazy fetches: the patch carries the target
tree and its new blobs, so checkout finds them locally. The checkout-mode "after"
wave used T2 because T1's patch already existed. Its miss made the same 7 HTTP
requests as each "before" job at T1.

## Timing

Medians, with ranges in brackets. Checkout time excludes saves.

| Case | n | Checkout | Snapshot restore | Patch restore + apply | Agent checkout phase |
| --- | ---: | ---: | ---: | ---: | ---: |
| Before, agent mode | 9 | 10.11s [9.30–14.04] | 4.70s | — | 5.12s |
| After, agent hit | 16 | 9.98s [8.09–13.10] | 5.33s | 0.74s [0.46–0.90] | 3.59s |
| Before, checkout mode (removed) | 9 | 9.51s [8.46–12.72] | 5.91s | — | — |
| After, checkout-mode hit (removed) | 8 | 7.64s [7.09–11.61] | 4.44s | 0.88s [0.55–1.42] | — |
| After, HEAD-build hits | 8 | 8.68s [7.78–10.04] | | | |
| After, blobless agent hits | 3 | 18.10s [16.86–20.41] | | | |

The agent hit's checkout phase is about 1.5s shorter because it no longer
fetches the commit or lazily fetches trees. That saving is within the Cache
restore's spread, so overall checkout time is about the same. Across all 44 hits,
patch restore and apply took a median 0.76s [0.46–1.42].

Misses and saves:

| Case | Checkout | Save, reported separately |
| --- | ---: | ---: |
| Treeless agent miss @T1 (build 45) | 11.84s | patch 1.20s |
| Blobless agent miss @T4 (build 46) | 18.32s | patch 1.72s |
| Treeless agent miss, agent-level skip-fetch, strict override @T2 | 33.52s | patch 1.67s |
| Blobless agent miss, agent-level skip-fetch, strict override @T5 | 124.00s | patch 1.73s |
| Patch saves, all 14 | — | median 1.31s [0.71–1.84] |
| Treeless snapshot seed @S (builds 44, 45) | 51.91s, 47.80s | snapshot 8.47s, 5.46s |
| Blobless snapshot seed @S | 104.10s | snapshot 26.18s |
| Snapshot refresh job (hit @T1, saves S′ = T1) | 11.08s | snapshot 8.77s |

The two agent-level skip-fetch rows set `checkout-override-mode=strict` and
`BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS=true` together, which simulates
operators who must enable skip-fetch in agent configuration. On a miss, the
agent's `rev-parse <sha>^{commit}` check with `GIT_NO_LAZY_FETCH` scanned every
promisor object before it failed: about 21s (treeless) and 107s (blobless)
before its fetch started. A hit under the same settings behaved like any other
hit (1 session, 11.43s). In a local check on a git.git clone, Ubuntu's Git 2.43.0
took 0.8s for the same query; Git 2.45.4, 2.47.3, 2.49.1 and 2.55 answered
immediately.

## Patch sizes

| Patch | Bytes |
| --- | ---: |
| S → T1, treeless / blobless | 466,565 / 508,840 |
| S → T5, blobless | 1,253,612 |
| S → T2, treeless | 1,590,347 |
| S → T3, treeless | 2,394,436 |
| S → T4, blobless | 2,618,154 |
| S → HEAD (`c339f40`), treeless | 3,364,569 |
| S′ = T1 → T2, treeless (T2 is an ancestor: trees and blobs only) | 1,179,134 |

Patches carry the new commits plus the target tree's new objects; they are not
thin packs. They grow with distance from the snapshot: 3.4 MB at 679 commits.
Repeated saves of the same patch differed by a few bytes, because pack output
is not byte-for-byte reproducible.

## Scenarios

* **Patch miss, then hits.** The first job missed, fetched as before, and saved
  the patch. All eight parallel jobs then hit, and the agent logged
  `Commit "…" already exists locally, skipping fetch`.
* **HEAD first job.** `BUILDKITE_COMMIT=HEAD` skipped patch restore, as designed.
  The agent resolved `c339f40`. Post-checkout saved the patch under that SHA, and
  eight jobs pinned to it hit. The agent skips verification for HEAD builds, so
  that job made no verification fetch.
* **First-wave stampede.** Four parallel jobs on new commit T3 all missed and
  fetched (12 HTTP requests each). All four saved under the same write-once key
  without errors. A later job hit.
* **Snapshot refresh.** A `max-age: 60` job restored S through a fallback key,
  hit its patch, and saved S′ = T1 under a new period key. A later job restored
  S′, the newest snapshot, through a fallback key. It looked up `[S′, T2]` and
  missed, even though `[S, T2]` existed: old patches simply stop matching. T2 is
  an ancestor of T1, so the commit was already local. The agent skipped its fetch,
  and checkout lazily fetched T2's trees and blobs. The saved `[S′, T2]` patch
  then served two hits at 2 HTTP requests and 1 session each.
* **Checkout mode (removed).** Hits made no upstream requests at all.

## Correctness

Each job checked offline, with Git transports forbidden, that it had:

* exactly the requested SHA
* the independently pinned tree (the GitHub API for the HEAD job), equal to
  `write-tree`
* clean status, promisor and filter configuration, no shallow file and no
  alternates
* the whole HEAD tree local

Treeless jobs also checked that `HEAD~10000`'s tree was still missing. All 79
rows in [patch-samples.csv](patch-samples.csv) passed. That CSV was exported from
each job's `result.json` artifact.

## Tested code and excluded numbers

Builds 45 and 46 ran the plugin as committed in
[`2bf8466`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/2bf84665cb4c40e988f4b1f353d48e75ec5a0bec).
The only difference was the wording of one pre-checkout warning. The checkout-mode
rows used `patch.py --mode checkout`; that option went with the mode.

Build 44 ran an earlier presence check, `cat-file -e`, that used the same slow
Git 2.43 lookup as the agent. It added about 18s to treeless misses and 113s to
blobless misses. The plugin now uses `rev-list --missing=print --no-walk`, which
never tries a lazy fetch. Build 44's miss timings (`aa-first`, `st-*`,
`bl-miss`) are kept in the CSV, but this report uses build 45 and 46 misses
instead. Request counts and all hit timings are unaffected.

Single-commit samples on one repository do not establish population tails.
Only Linux on hosted-large was measured.

## Sources

Build logs and artifacts require organization access.

* Sanity run: [build 43](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/43)
* Before/after waves, HEAD build, stampede, blobless, refresh: [build 44](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/44)
* Miss path after the probe fix, HEAD build, agent-level skip-fetch: [build 45](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/45)
* Blobless miss after the fix, blobless agent-level skip-fetch: [build 46](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/46)

The pipeline was parked with a manual block afterwards.
