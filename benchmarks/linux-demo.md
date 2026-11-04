# Linux README chart: sources and timing scopes

The [README chart](../docs/linux-benchmark.svg) summarizes Linux kernel checkout
strategies on `hosted-large` with mirrors off. It combines **native job run times
from one production demo build** with a **controlled Git-snapshot checkout
median from 16 runs**. These use different timing scopes and are not
revision-matched. Do not infer an exact speedup ratio from the bars.

## Chart data

| Bar | Displayed time | Measurement | Samples |
| --- | ---: | --- | ---: |
| Full clone | 4m 7s | Per-job run time, agent defaults | 1 |
| Blobless | 4m 14s | Per-job run time, 8 checkout workers | 1 |
| Treeless | 3m 30s | Per-job run time, 8 checkout workers | 1 |
| Shallow (depth 1) | 3m 25s | Per-job run time, 8 checkout workers | 1 |
| Git-snapshot | ~10s | Median controlled checkout, snapshot + patch hit, 8 workers | 16 |

All bars share a linear scale starting at zero (two pixels per second). The
Git-snapshot bar uses the unrounded median, **9.98s**, and rounds only its label.

### Production demo: per-job run time

Native numbers were transcribed from Ming's supplied Steps-view screenshot.
The screenshots do not show the build number, so these values are not attributed
to build #5 or a particular commit. The
[demo pipeline YAML](https://github.com/buildkite-playground/linux/blob/git-snapshot-demo/.buildkite/pipeline.yml)
defines the variants. Each job runs only `git rev-parse HEAD` after checkout.

"Ran in" is the individual job's run time, **excluding queue wait**. It includes
plugin setup where applicable, checkout, hooks and the command; it is not
isolated clone time. Group spans include queue wait and staggered starts and
are not used in the chart.

The two warm Git-snapshot jobs in that screenshot ran in **15s and 13s**.
The previous chart used 15s, the slower of the two, to avoid selecting the best
job. The current ~10s bar instead comes from the separate controlled median
below; it is not a reinterpretation of either job's run time.

Job #2's log explicitly says **"Waited 6s · Ran in 13s"**. Its visible groups show
snapshot restore 6.1s, patch restore 1.7s, agent checkout ("Preparing working
directory") 4.4s, post-checkout 0.1s and a cache-save check 0.3s. The cache already
existed, so nothing was saved. These rounded group durations are not an
independently measured checkout total. Neither the 25s Steps-view group span nor
the earlier 30s waterfall group span measures one job's checkout.

### Controlled Git-snapshot median

The [patch-cache report](patch-cache.md#timing) records an agent-mode patch-hit
checkout median of **9.98s, n=16**, range **8.09–13.10s**. The samples are the
`aa-1` through `aa-8` rows in each of builds 44 and 45 in
[patch-samples.csv](patch-samples.csv): new plugin, agent mode, treeless,
strict branch verification, snapshot and patch hits. The `aa-off` sample and
the removed plugin-owned checkout mode are not included.

[patch.py](patch.py) times a nested
`buildkite-agent bootstrap --phases=plugin,checkout` from bootstrap start until
the post-checkout hook starts. This includes plugin preparation, snapshot
restore, patch restore/apply and agent checkout, but **excludes saves, outer-job
setup and queue wait**. Mirrors are explicitly disabled inside the nested
bootstrap. Its timing scope is narrower than the demo's whole-job run time.
Build links, versions, correctness checks and seed/save measurements are in the
[full report](patch-cache.md).

## Variants and limitations

* **Full clone:** agent defaults; no partial-clone filter or depth limit.
  The demo also measured full clone with eight workers at 4m 19s. That redundant
  row is omitted from the chart, not treated as another independent build.
* **Blobless:** `--filter=blob:none`, eight workers. Fetches blobs on demand.
* **Treeless:** `--filter=tree:0`, eight workers. Keeps commit history, fetching
  trees and blobs on demand. Path history and blame can trigger many lazy
  fetches and become slow; see [history probes](treeless.md#lazy-history-operations).
* **Shallow:** `--depth=1`, eight workers. Loses history and can break merge-base
  and other history-dependent tools.
* **Git-snapshot:** restores cached Git metadata and a per-commit patch, then
  lets the agent check out with eight workers. These are **warm hits**; snapshot
  seeding, first-commit patch creation and periodic refresh cost extra. The
  default treeless filter has the same path-history trade-off; use
  `treeless: false` for those jobs.

The native data is **n=1 per variant, all from one build**, not a typical-time
estimate. Sixteen controlled patch hits provide repeat evidence for the warm
checkout path, not population tails or a repeated matched comparison with the
native variants. No fresh benchmark campaign was run for this chart update.

For a matched repeat comparison, run five more builds in the mirror-free demo
organization, pinning the same Linux commit and plugin revision, with fresh
agents and fixed Git/agent versions and flags. Prime the snapshot and target
patch separately, verify hits, and record misses/refreshes separately. Collect
each native job's and both snapshot jobs' individual start/finish times and
build URLs, never group spans. Report per-variant medians and ranges with one
consistent timing scope before replacing this summary with a matched chart.

## Verification

The 16-row CSV selection reproduces 9.98s (range 8.09–13.10s). SVG XML, displayed
labels and proportional bar widths were checked against the data above. The
chart was inspected as a README image in Chromium with GitHub-rendered Markdown
and GitHub-style light and dark themes; no clipped text was found.
