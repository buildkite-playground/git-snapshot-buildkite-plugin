# Mirror-aware agent checkout and treeless snapshots — 2026-10-28

Tested plugin revision:
[`0987807`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/09878075130998d6162688e902b8069367f6682a).
The benchmark harness at
[`bb0ddc6`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/bb0ddc61e131994ac6456cd30b20dbdb0a48689c)
corrects an offline validation check; the plugin implementation is unchanged.
Treeless was opt-in at the tested revision. The current default is treeless;
see the main README for the path-history opt-out and current behavior.

## What these numbers mean

Warm comparisons use the default **agent-owned pre/post hooks**, in controlled
`buildkite-agent bootstrap --phases=plugin,checkout` invocations on hosted-large
with mirrors explicitly off. They include plugin setup, Cache restore, the
agent's SHA/branch fetches, parallel checkout and clean. They exclude queue and
machine startup, correctness checks, probes and artifact upload. They are not
unmodified hosted-job wall times. No target repository code was executed, no
cache volumes were declared, and no cluster settings were changed.

Git 2.43.0 and agent 4.7.0+15166.413a004b6a7aa607fa718fe2f64cc960c42d4419;
Open Source cluster, hosted-large queue. Full history, strict agent commit
verification, no submodules/LFS, fetch flags `-v --prune`, eight checkout workers.
The initial clones retain branch/tag refs; the saved index is omitted. Filter
types have independent Cache keys. Refresh is disabled for warm measurements.

## Fresh Chromium snapshot: blobless versus treeless

Public repository: `https://github.com/chromium/chromium.git`.
SHA `4788ec5227b130aabee8c86ac73a4f97f8907229`, independently pinned tree
`494d2b8c7be59565fa056e944bfa10040d427c5b`.
512,501 tracked entries, 1,853,106 reachable commits, 4,379,778,982 worktree
logical bytes (4.38 GB, excluding `.git`). This is the Git repository alone,
not a gclient dependency checkout or build.

| Snapshot | n | Archive bytes (decimal GB) | Warm median | Warm p90 |
| --- | ---: | ---: | ---: | ---: |
| Blobless (`treeless: false`) | 10 | 6,269,004,304 (6.27) | **57.18s** | **60.27s** |
| Treeless (`treeless: true`) | 10 | 2,561,344,667 (2.56) | **32.85s** | **35.85s** |

Treeless was 59.1% smaller and its observed median 42.6% lower in this sample.
Those are workload-specific observations, not a population performance claim.
Each filter used three sequential jobs followed by seven overlapping jobs on
separate agents. p90 is nearest rank: the ninth sorted observation out of ten.
This small sample does not establish production tail latency. The filters were
sampled in separate waves, not a randomized paired experiment.
The seven blobless bootstrap starts spanned 1.27s; treeless starts spanned 2.24s.
All seven bootstrap intervals overlap within each filter. Sequential/concurrent
medians were 59.53s/56.26s blobless and 34.47s/32.24s treeless; the distributions
and outliers are retained, not filtered to make the comparison look cleaner.

All twenty samples passed pinned SHA/tree, matching index tree, clean status,
local HEAD-object, full-history, canonical promisor origin and no-alternates
checks. Blobless retained missing historical blobs; treeless retained a missing
historical tree. Both made **two fetch invocations per warm bootstrap** (the
agent's normal fetches), not a checkout-time storm of single-tree fetches.

The blobless pre/post cold seed took 471.56s including save (n=1). The original
treeless cold seed saved successfully but then failed the initial validation
command: `git show --no-patch` attempted to load an intentionally absent old
tree. The harness was fixed to read the raw commit header; its cold timing is
excluded, and subsequent warm samples passed the corrected check.

### Linux cross-check

The same controlled agent-owned path passed three sequential samples per filter:

| Snapshot | Archive bytes | n | Warm median | Range |
| --- | ---: | ---: | ---: | ---: |
| Blobless | 2,146,989,988 | 3 | 16.22s | 13.21–16.63s |
| Treeless | 1,021,213,296 | 3 | 11.42s | 9.21–11.81s |

SHA `44dc57ed1e77a23248ef28732486f4b7e9468cf7`, expected tree
`c2f61d5e11c0d9b0e553d475d13406e4ac136279`; 97,235 entries,
1,501,533 reachable commits, 1,672,794,078 worktree logical bytes. Both filters
made two normal agent fetch invocations per warm sample. Linux is a smaller
cross-check, not another n=10 distribution. The blobless cold seed took 124.73s
including save (n=1); its original treeless cold validation had the same harness
issue as Chromium and is excluded from cold timing claims.

## Old snapshot, newer commit — checkout without save

These Chromium tests deliberately use **plugin-owned `mode: checkout`** in the
controlled bootstrap. They are not pooled with the default pre/post warm set.
The stale seeds fetch only the old pinned ancestry, rather than cloning all
current branch refs, which would already contain the supposedly newer commit.
Their archives are consequently a different object set: 5,777,056,968 bytes
blobless and 2,448,301,692 bytes treeless. Both seeds passed correctness checks.

Separate offline audit jobs proved saved HEAD was the old SHA and the new
commit was absent. The blobless audit enumerated locally stored object IDs,
including a positive check for old HEAD, avoiding promisor fetch behavior on a
missing-object lookup. The first such lookup audit in build 15 was canceled
after stalling; none of its timed steps ran. Treeless audit used a lookup with
transports forbidden. Audit restores were outside the timed jobs.

New SHA `93e90142595090aee3acaaa8880d406701e8242f`, expected tree
`5b60b45c3d2deb16e87c853f770eb345bd144d39`: eleven more reachable commits and
512,502 entries. `max-age: 1` selects an aged fallback key without waiting a day;
it does not simulate a day's typical repository churn.

| Filter | No-save checkout, n=1 | Fetch invocations | Separate refresh save, n=1 |
| --- | ---: | ---: | ---: |
| Blobless | **54.28s** | 3 | **33s** |
| Treeless | **32.06s** | 4 | **15s** |

The first column is an actual `refresh: false` run, not a total with guessed
save time subtracted. It includes restore, delta fetch, checkout and worktree
installation. The extra treeless fetches stayed bounded; there was no
thousand-request checkout storm. A second job per filter restored the same old
seed with refresh enabled: 86.08s blobless and 41.04s treeless total. Save times
are the hook's whole-second stopwatch and include compression/upload, not an
inferred difference between two variable jobs. Those jobs confirmed successful
new saves. Single observations do not define a stale latency distribution.

For the earlier blobless Linux/Chromium runs, timestamped logs allow the
requested historical decomposition (different implementation/snapshot sets):

| Earlier repository sample | n | Checkout excluding save | Save | Original total |
| --- | ---: | ---: | ---: | ---: |
| Linux build 34 | 1 | approximately 22.010s | 18.830s | 40.840s |
| Chromium build 8 | 1 | approximately 77.834s | 51.679s | 129.513s |

These are **log-derived** values; see [the earlier report](README.md) for exact
timestamp bounds. No new Linux treeless stale distribution is claimed.

## Lazy history operations

Each probe starts with an independent object-store copy of the same fresh
checkout. Existing immutable packs are hardlinked; newly fetched packs stay in
that copy. Probes do not warm each other or alter the saved archive. Auto-GC,
Git hooks and recursive submodule fetches are disabled. The 50/500 bases are
**first-parent** ancestors (`HEAD~50`, `HEAD~500`), not necessarily 50/500 total
reachable commits. Merge-base uses that base and HEAD; diff is the default
`git diff --name-only <base>..HEAD`, with no special rename override.
Path logs use `--format=%H` to compare commit IDs rather than message formatting.

Fetch counts below are Git `fetch` command invocations from Trace2, including
lazy children, **not HTTP request counts**. Pair timings sum merge-base and diff.
Each row has n=1 per filter; these are diagnostic observations, not distributions.

| Chromium operation | Blobless time / fetches | Treeless time / fetches |
| --- | ---: | ---: |
| Merge-base + name-only diff, base ~50 | 0.027s / 0 | 2.888s / 1 |
| Merge-base + name-only diff, base ~500 | 1.669s / 2 | 4.210s / 3 |
| `git log -n 50 -- DEPS` | 0.021s / 0 | **Timed out at 300s / 96** |

Both successful name-only diff outputs were identical across filters (257 and
5,049 paths respectively; SHA-256 hashes recorded). Merge-base itself took
about 3ms/11ms for blobless and 3ms/16ms for treeless at the two depths. Treeless
path-log returned only **22 of the requested 50 commits** before termination;
it is not a successful 300s result. Blobless returned all 50. The default
name-only diff is not always network-free even with blobless snapshots, as the
~500 case demonstrates; this experiment did not isolate why it fetched blobs.

Linux corroborates the path-walking risk, using `MAINTAINERS`:

| Linux operation | Blobless time / fetches | Treeless time / fetches |
| --- | ---: | ---: |
| Merge-base + name-only diff, base ~50 | 1.041s / 2 | 1.796s / 3 |
| Merge-base + name-only diff, base ~500 | 1.270s / 2 | 1.889s / 3 |
| `git log -n 50 -- MAINTAINERS` | 0.013s / 0 | **150.432s / 199** |

All Linux probe outputs, including all 50 log commits, matched across filters.
This is why treeless is opt-in: it fits checkout-only CI much better than jobs
that walk historical paths. Authentication and a reachable origin are still
needed at job time. Smaller archives do not make missing history free.

## Hosted mirror compatibility

Default mode now skips **both restore and save** when
`BUILDKITE_GIT_MIRRORS_PATH` is nonempty. The successful native control in
[Linux pipeline build 37](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/37)
used this public plugin repository, the real agent checkout and unchanged
protected hosted settings. Logs confirmed both bypass messages, a clean exact
checkout and no snapshot marker. The official tester, plugin linter and
ShellCheck also passed there. This is a small-repository compatibility control,
not a large-repository speed measurement.

The native Linux attempt in
[build 36](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/36)
also correctly bypassed snapshots, then the agent's ordinary mirror clone hit
`fetch-pack: invalid index-pack output`; it was canceled rather than waiting
through repeated retries. The underlying mirror failure is not established and
the plugin does not repair it. No successful native large-Linux snapshot time is
claimed. Controlled mirrors-off measurements must not be presented that way.

Earlier hook opt-out diagnostics in
[build 35](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/35)
showed that the agent protected both mirror-path and skip-update variables.
Source inspection confirms skip-update would also prevent mirror creation if
accepted, but these hosted hooks cannot set it. The default design therefore
never tries. Snapshot acceleration in default mode requires mirrors off;
`mode: checkout` remains explicit opt-in when that is not possible, with its
documented loss of agent checkout orchestration.

The explicit opt-in also passed a native mirrors-on small-repository control in
[build 40](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/40),
with the agent's normal checkout skipped and a clean, independent partial clone.
Its first control attempt (build 39) used an abbreviated API commit ID that the
Git server could not fetch as a ref; the rerun used a full SHA. Neither is part
of a performance distribution.

Several earlier native jobs started cold mirrors. That is evidence of missing
seeded contents, not of absent volume mounts or a fleet attachment rate. The
1,762s Chromium baseline in the [earlier report](README.md) is a controlled
default full clone with mirrors off, **not a timed native mirror creation**.

## Evidence and limitations

[round3-samples.csv](round3-samples.csv) contains all 34 accepted checkout
records; [round3-probes.csv](round3-probes.csv) contains each probe command,
return status, output hash and pair-level fetch count. The raw JSON bundle,
including Trace2 summaries, archive observations and the two offline audits, is
`round3-results.zip` in
[collector build 41](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/41).
The collector asserted sample counts, correctness, matching successful probe
outputs, two agent fetches per warm sample and overlapping burst bootstraps.

Sources: Chromium seeds [10](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/10),
treeless warm/probes [11](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/11),
blobless warm/probes [12](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/12),
pinned-history stale seeds [13](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/13),
treeless stale/audit/save [14](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/14),
blobless stale/audit/save [16](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/16);
Linux warm/probes [38](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/38).
Build logs and artifacts require organization access.

Every accepted run began with at least 157.1 GiB free; the minimum observed
headroom across the 34 runs was 127.4 GiB. The harness rejects less than 120 GiB
initially and aborts below 8 GiB. Archive sizes are exact observed outer ZIP
lengths, not rounded CLI text; duplicate staging filenames are not added
together. Worktree sizes are logical bytes, not allocated blocks.

Network, GitHub server, Cache and host variability remain uncontrolled. Cold
seeds, stale runs and probes are n=1 per case, except explicitly excluded failed
validation attempts. The two filter waves were not randomized. This round did
not repeat the earlier full-clone baseline, test private-repository credentials,
or benchmark submodules/LFS/sparse checkout. No fleet mirror-attachment claim
or native large-repository snapshot speed claim follows from these experiments.
Both temporary pipelines were parked after collection; the Linux repository
setting was restored. No cluster settings were changed.
