# Earlier hosted checkout measurements — 2026-10-28

This is the earlier round, using the plugin's **checkout hook**. That mode has
since been removed: the plugin no longer performs checkouts, and the agent always
checks out after the plugin's pre-checkout restore. These numbers are kept as
history, not as a recommendation. See the main README for current behavior.
The tested final revision is
[`5bfe21e`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/5bfe21e2783db5316a6352ff3ac1ddb1ac412634).
Its hook is identical to the preceding
[`bfdb0ab`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/bfdb0abe388981d99c62e3fb542d54bdae4ac53c)
revision; the last change only
isolates the archive observer from target repository fixtures.

## What the stopwatch measures

All controlled numbers below are wall time for a real
`buildkite-agent bootstrap --phases=plugin,checkout`, including plugin download,
Cache restore, Git fetch, parallel checkout, and any cold/stale Cache save.
They exclude queue time, agent startup, correctness validation and artifact
upload. They are not the materialization-only stopwatch from earlier experiments.

[checkout.py](checkout.py) runs the experiment, observes ZIP lengths through open
file descriptors, records root Git Trace2 durations and polls disk headroom.
No target repository commands, builds or hooks are executed. No cache volumes
are used. The plugin disables Git hooks; controlled bootstraps disable local
checkout hooks.

Environment: Buildkite Open Source cluster, `hosted-large`, Git 2.43.0,
agent 4.7.0+15166.413a004b6a7aa607fa718fe2f64cc960c42d4419.
Controlled bootstraps explicitly disable mirrors and use strict commit
verification, no submodules/LFS, clone flags `-v` (plus `--filter=blob:none`
for the blobless baseline), and fetch flags `-v --prune`.
The agent's native hosted checkout is a separate experiment below.

## Chromium: real history and more than 500,000 entries

Repository: `https://github.com/chromium/chromium.git`.
Old revision: `4788ec5227b130aabee8c86ac73a4f97f8907229`, independent expected
tree `494d2b8c7be59565fa056e944bfa10040d427c5b`.
New revision: `93e90142595090aee3acaaa8880d406701e8242f`, expected tree
`5b60b45c3d2deb16e87c853f770eb345bd144d39`.

| Strategy | n | Seconds | Notes |
| --- | ---: | ---: | --- |
| Agent default full clone | 1 | 1762.3 | No existing repo/mirror |
| Agent plain blobless clone | 1 | 715.6 | Same default checkout worker settings as agent |
| Plugin cold miss + checkout + save | 1 | 345.6 | Fresh namespace; successful save confirmed |
| Plugin warm | 11 | **median 65.7; p90 68.3** | All audited hits; range 53.0–69.3 |
| Plugin stale + newer commit + refresh | 1 | 129.5 | Genuine delta; successful new save confirmed |

The warm set is three sequential samples followed by eight concurrently running
jobs on separate agents. All eight started within 2.0 seconds and overlapped.
Sequential median: 59.9s (n=3). Concurrent median: 66.8s (n=8).
The pooled median is the sixth sorted observation; p90 uses nearest rank, the
tenth of eleven. These small samples do not establish a population tail latency.
The first warm fetch took 28.2s; the other ten took 0.12–0.18s. The slower sample
is retained; its cause is not established.

| Size/count at old revision | Value |
| --- | ---: |
| Tracked entries (`git ls-files -z`) | 512,501 |
| Reachable commits (`git rev-list --count HEAD`) | 1,853,106 |
| Worktree logical bytes, excluding `.git` | 4,379,778,982 (4.38 GB) |
| Full-clone `.git` logical bytes | 69,672,639,172 (69.67 GB) |
| Plain blobless-clone `.git` logical bytes | 6,792,726,250 (6.79 GB) |
| Plugin `.git` logical bytes | 6,233,480,153 (6.23 GB) |
| Compressed blobless Cache archive | 5,772,895,934 (5.77 GB) |

Sizes use decimal GB; logical `du -sb` sizes are not allocated disk usage.
Tracked entries include any symlinks/gitlinks; this is Chromium's Git tree, not
a complete `gclient` dependency checkout. There is no dependency download/build.
The archive observer sees both inner/outer ZIPs and repeated restore staging
names: the final outer archive is reported once, not summed with those copies.

Initial disk headroom was 168,727,715,840 bytes (157.1 GiB). The full-clone run
bottomed at 93,056,872,448 bytes (86.7 GiB free); the snapshot cold/stale runs
bottomed near 145.0 billion bytes (135.1 GiB free). The harness requires 120 GiB
initially and aborts below 8 GiB free. No run hit either limit.

### Stale is not a mislabeled warm run

Before timing, a diagnostic restore proved the saved HEAD was the old SHA and
the new commit was absent, with all Git transports forbidden. That diagnostic
copy was deleted. The timed plugin then restored the same old archive, fetched
the new SHA in 0.295s and checked out in 8.693s. Fetch output recorded 57 history
objects / 10.54 KiB, then 19 blobs / 113.98 KiB, not a full-history redownload.
It saved a new 5,773,200,828-byte archive successfully. The new tree has 512,502
entries and 1,853,117 reachable commits: eleven actual commits newer than seed.

`max-age: 1` made the existing seed stale and selected a fresh immutable period
key. This tests the age/refresh path without waiting a day; it does not claim
that eleven commits represent a full day's typical Chromium churn.

### Stale checkout excluding the periodic save

The earlier plugin-owned stale samples can be decomposed using timestamped
Cache-start and plugin save-end log lines. These are approximate log-derived
intervals, not new runs or separately instrumented phase stopwatches:

| Repository | n | Total bootstrap | Cache save interval | Total minus save |
| --- | ---: | ---: | ---: | ---: |
| Linux, build 34 | 1 | 40.840s | 18.830s | **22.010s** |
| Chromium, build 8 | 1 | 129.513s | 51.679s | **77.834s** |

Linux save bounds: Unix milliseconds 1793182658717–1793182677547;
Chromium: 1793182911738–1793182963417. The subtraction retains plugin setup,
restore, delta fetch, checkout and final worktree installation. Save is a real
once-per-period cost and is not included in the typical stale checkout figure.

### Interpretation

The single full/blobless baseline observations were about 26.8×/10.9× the warm
median. These are **observed ratios, not repeated baseline distributions**.
Baselines fetch default refs; the plugin fetches the pinned commit's ancestry
and uses eight checkout workers. Their object sets differ, as the `.git` sizes
show. This comparison evaluates practical strategies, not the isolated effect
of Cache with identical object graphs or identical checkout settings.
GitHub/network/host/Cache variability is not controlled across separate agents.
Warm samples use the same SHA; the stale sample alone covers a newer SHA.
Snapshot seeding and periodic refreshing are real costs, not part of warm time.

## Linux: design comparison and hosted viability

Old SHA `44dc57ed1e77a23248ef28732486f4b7e9468cf7`, expected tree
`c2f61d5e11c0d9b0e553d475d13406e4ac136279`.
New SHA `6b4b543fa18757297ac756a6fe6e64f506b7844a`, expected tree
`f13b99af8ebec110d485c502786eb77d7929c271`.

| Controlled design (mirrors off) | Cold | Warm | Stale + refresh | n per case |
| --- | ---: | ---: | ---: | ---: |
| Experimental agent-owned pre/post | 116.9s | 20.2s | 31.2s | 1 |
| Final checkout hook, audited build 34 | 144.4s | 22.8s | 40.8s | 1 |

Both passed correctness checks. Single observations do not establish a speed
winner. Final stale fetch transferred 78 history objects / 17.87 KiB and eleven
blobs / 71.37 KiB, not the 8.75-million-object history. Both final cold and stale
saves succeeded. The old revision has 97,235 entries and 1,501,533 commits;
the new revision has fifteen more commits. Final cold archive: 2,147,811,864 bytes.

**Real hosted jobs, protected mirrors unchanged** — not nested bootstraps:

| Design | Result | Job wall time |
| --- | --- | ---: |
| Agent-owned pre/post warm, build 29 | Failed: full mirror clone repeatedly failed after Cache restore | 662.3s |
| Final checkout-hook warm, build 31 | Passed; plugin reported 11s | **13.825s**, including validation |

The agent's existing-repository detection skips a working clone, but its mirror
update occurs before that branch. A restored `.git` therefore does not bypass
protected hosted mirror creation. We observed six mirror clone failures with
`fetch-pack: invalid index-pack output`; their underlying cause is not proven.
Pipeline-level mirror-path/skip-update values could not override the protected
settings. The custom checkout hook avoids that path without changing the
cluster. It is the final default, with the agent-knob limitations in the main
README at that revision. This is not evidence that pre/post is fast on
unmodified hosted agents. The current default instead bypasses snapshots
entirely when mirrors are enabled, leaving normal agent checkout untouched.

The experimental revision remains in history at
[`cf1c8b2`](https://github.com/buildkite-playground/git-snapshot-buildkite-plugin/commit/cf1c8b213422011732a236d16c9e5c031806f580).
It carries a real negotiation ref, promisor/filter and parallel checkout config,
and removes the stale index. Its plain-agent-fetch delta regression passed
locally. However, Chromium's experimental warm run fetched roughly 1.67 million
additional objects and imported roughly 40,000 tag refs before autopacking; it
was canceled and is not an accepted warm result. The experimental snapshot
rebuild retains only its synthetic branch, not the source branch/tag refs.
Those observations need further investigation before recommending this variant
for large tagged repos, independently of the hosted mirror issue.

## Correctness and evidence

Every accepted controlled sample asserts the exact pinned SHA, an independently
provided tree, matching `write-tree`, clean status, canonical origin, no shallow
history and no alternates. All HEAD-tree objects must be local with Git
transports forbidden. Partial-clone samples must retain missing historical
objects and the promisor/blobless configuration. Warm logs and Trace2 were
audited: restore hit, no unusable-snapshot retry, no fresh `git init` fallback.

[samples.csv](samples.csv) is exported directly from the original `result.json`
artifacts, not transcribed timings. The full JSON bundle with Trace2 summaries,
archive observations, versions and validations is `benchmark-results.zip` in
[collector build 9](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/9).
Build logs/artifacts require organization access.

Source builds:

* Chromium accepted default-clone job: [build 1](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/1#01a181dd-3f1f-44e9-a415-576b681ce009).
* Chromium accepted blobless-clone job: [build 2](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/2#01a181de-6314-46c6-92f2-33dc925d35fb).
* Chromium final cold + eleven warm: [build 7](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/7).
* Chromium final stale: [build 8](https://buildkite.com/buildkite/temporary-chromium-git-snapshot-benchmark-20261028-ming/builds/8).
* Linux controlled pre/post: builds [28](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/28), [29](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/29), [30](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/30).
* Linux native final hook: [build 31](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/31).
* Linux final audited cold/warm/stale: [build 34](https://buildkite.com/buildkite/temporary-large-linux-checkout-benchmark-20261026-ming/builds/34).

Both temporary pipelines were parked with a manual block after collection.
Cluster settings were not changed.

### Excluded attempts and limits

* Chromium builds 1/2 also contain failed experimental snapshot jobs. Only the
  individually passing baseline jobs listed above are included, not those builds
  as blanket successes. Earlier setup/contract attempts are not measurements.
* Experimental Chromium warm build 4 was canceled during the extra fetch/gc.
* Earlier final-hook attempts (Chromium builds 5/6) used a recursive archive
  watcher that scanned the worktree and mistook ZIP/JAR fixtures for archives.
  They were canceled/excluded, the watcher was narrowed to Cache staging paths,
  and all final-hook measurements were rerun with the corrected observer.
* Linux build 33 hit a Cache upload HTTP 500. The hook correctly left a usable
  checkout, but subsequent supposed-warm work was a miss. Those are not warm
  measurements; build 34 used a fresh namespace and confirmed both saves/hits.
* Linux build 32 passed but used the earlier observer. Its 120.1/16.8/33.1s
  cold/warm/stale observations are not pooled with the audited build 34 set.
* Only Linux has a native protected-mirror hosted-job validation. Chromium's
  measured strategies use controlled bootstraps. No other OS is validated here.
* No promise is made about submodules, LFS, sparse checkouts, dependency trees,
  full-clone history commands or private-repository authentication performance.
  `origin` stays promisor; history-walking commands still need job-time Git auth.
  Repeated refreshes retain previously hydrated blobs, so future archive size
  can grow; rotate the key prefix to re-seed when needed.

## Reproduce

Run [checkout.py](checkout.py) in a disposable hosted-large job with outer
checkout skipped. Set `BUILDKITE_REPO`, pinned `BUILDKITE_COMMIT`, independent
`BENCH_EXPECTED_TREE` and a dedicated `BUILDKITE_BUILD_CHECKOUT_PATH`.
Use a fresh `--prefix` for cold, the same prefix and `--read-only` for warm,
then a proven-absent newer commit with `--max-age 1` for stale. Keep the Cache
store/policy compatible across jobs. Use `default` and `blobless` modes for
baselines, and pass the reviewed `--plugin-ref` to all modes. Download the
harness from the same pinned revision before timing. Do not run target code.

To recalculate the recorded warm statistics from the CSV:

```python
import csv, math, statistics
with open("benchmarks/samples.csv") as f:
    samples = list(csv.DictReader(f))
warm = sorted(float(r["bootstrap_seconds"]) for r in samples
              if r["repo_name"] == "chromium" and "warm" in r["case"])
print(len(warm), statistics.median(warm), warm[math.ceil(.9 * len(warm)) - 1])
# 11 65.667481684 68.304079046
```
