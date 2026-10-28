#!/usr/bin/env python3
"""Checkout-only hosted benchmark. Never runs commands from the target repository."""
import argparse
import datetime
import json
import os
from pathlib import Path
import shutil
import subprocess
import threading
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("mode", choices=["snapshot", "blobless", "default"])
parser.add_argument("--plugin-ref", required=True)
parser.add_argument("--prefix", required=True)
parser.add_argument("--max-age", type=int, default=86400)
parser.add_argument("--read-only", action="store_true")
args = parser.parse_args()
checkout = Path(os.environ["BUILDKITE_BUILD_CHECKOUT_PATH"])
result_dir = Path("/tmp") / ("git-snapshot-results-" + os.environ["BUILDKITE_JOB_ID"])
result_dir.mkdir()
temporary = result_dir / "temporary"
temporary.mkdir()
free_before = shutil.disk_usage(checkout).free
assert free_before > int(os.environ.get("BENCH_MIN_FREE_GIB", "120")) * 1024**3, "Insufficient initial disk headroom"
env = dict(os.environ, BUILDKITE_SKIP_CHECKOUT="false", TMPDIR=str(temporary),
           GIT_TRACE2_EVENT=str(result_dir / "git-trace.json"))
# Hook refreshes re-read these values; match the explicit bootstrap CLI flags.
env.update(BUILDKITE_GIT_MIRRORS_SKIP_UPDATE="true", BUILDKITE_GIT_SUBMODULES="false",
           BUILDKITE_GIT_LFS_ENABLED="false", BUILDKITE_GIT_COMMIT_VERIFICATION="strict",
           BUILDKITE_GIT_FETCH_FLAGS="-v --prune",
           BUILDKITE_GIT_CLONE_FLAGS="-v --filter=blob:none" if args.mode == "blobless" else "-v")
env["BUILDKITE_PLUGINS"] = json.dumps([
    {"github.com/buildkite-playground/git-snapshot-buildkite-plugin#" + args.plugin_ref: {
        "key-prefix": args.prefix, "max-age": args.max_age,
        "refresh": not args.read_only}}
]) if args.mode == "snapshot" else "[]"
command = ["buildkite-agent", "bootstrap", "--phases=plugin,checkout",
           "--git-mirrors-path=", "--git-mirrors-skip-update=true",
           "--local-hooks-enabled=false", "--no-job-api",
           "--git-submodules=false", "--git-lfs-enabled=false",
           "--git-commit-verification=strict",
           "--git-clone-flags=" + ("-v --filter=blob:none" if args.mode == "blobless" else "-v"),
           "--git-fetch-flags=-v --prune"]

# Hold descriptors across unlink long enough to fstat final ZIP lengths, rather
# than estimating archive sizes from rounded/colored CLI output. Git packs are
# not ZIP files. Polling may miss very short-lived files: report that explicitly.
archives = []
stop = threading.Event()
def watch_archives():
    opened = {}
    seen = set()
    while not stop.wait(0.1):
        for root, _, names in os.walk(temporary):
            for name in names:
                path = Path(root) / name
                if path in opened or path in seen:
                    continue
                try:
                    stream = path.open("rb")
                    if stream.read(4) != b"PK\x03\x04":
                        stream.close()
                        continue
                    opened[path] = stream
                except OSError:
                    continue
        for path, stream in list(opened.items()):
            stat = os.fstat(stream.fileno())
            if stat.st_nlink == 0:
                archives.append({"bytes": stat.st_size, "path": str(path.relative_to(temporary))})
                stream.close()
                seen.add(path)
                del opened[path]
    for path, stream in opened.items():
        archives.append({"bytes": os.fstat(stream.fileno()).st_size,
                         "path": str(path.relative_to(temporary))})
        stream.close()

watcher = threading.Thread(target=watch_archives)
watcher.start()
start = time.monotonic()
utc_start = datetime.datetime.now(datetime.timezone.utc).isoformat()
process = subprocess.Popen(command, cwd=checkout, env=env)
minimum_free = free_before
abort = None
while process.poll() is None:
    free = shutil.disk_usage(checkout).free
    minimum_free = min(minimum_free, free)
    if free < 8 * 1024**3 or time.monotonic() - start > 5400:
        abort = "disk headroom below 8 GiB" if free < 8 * 1024**3 else "90-minute checkout limit"
        process.terminate()
        break
    time.sleep(0.2)
return_code = process.wait()
seconds = time.monotonic() - start
stop.set()
watcher.join()
result = {"mode": args.mode, "plugin_ref": args.plugin_ref, "prefix": args.prefix,
          "read_only": args.read_only, "max_age": args.max_age,
          "build_url": os.environ["BUILDKITE_BUILD_URL"], "job_id": os.environ["BUILDKITE_JOB_ID"],
          "repo": os.environ["BUILDKITE_REPO"], "requested_commit": os.environ["BUILDKITE_COMMIT"],
          "started_at": utc_start, "bootstrap_seconds": seconds,
          "return_code": return_code, "abort": abort,
          "free_before_bytes": free_before, "minimum_free_bytes": minimum_free,
          "archives_observed": archives, "archive_poll_seconds": 0.1,
          "git_version": subprocess.check_output(["git", "--version"], text=True).strip(),
          "agent_version": subprocess.check_output(["buildkite-agent", "--version"], text=True).strip()}

# Trace2 root Git processes distinguish checkout from its lazy fetch children.
trace = result_dir / "git-trace.json"
sessions = {}
if trace.exists():
    for line in trace.read_text().splitlines():
        event = json.loads(line)
        sid = event.get("sid", "")
        if "/" in sid:
            continue
        state = sessions.setdefault(sid, {})
        if event["event"] == "cmd_name":
            state["command"] = event["name"]
        elif event["event"] == "def_repo":
            state["worktree"] = event.get("worktree")
        elif event["event"] == "exit":
            state["seconds"] = event["t_abs"]
result["git_root_processes"] = list(sessions.values())

if return_code == 0 and abort is None:
    validation_env = dict(os.environ, GIT_ALLOW_PROTOCOL="", GIT_NO_LAZY_FETCH="1")
    def git(*arguments):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *arguments],
                                       cwd=checkout, env=validation_env, text=True).strip()
    sha = git("rev-parse", "HEAD")
    assert sha == os.environ["BUILDKITE_COMMIT"]
    tree = git("rev-parse", "HEAD^{tree}")
    assert tree == os.environ["BENCH_EXPECTED_TREE"], "Independent pinned tree differs"
    assert tree == git("write-tree")
    assert not git("status", "--porcelain")
    assert git("config", "remote.origin.url") == os.environ["BUILDKITE_REPO"]
    assert git("rev-parse", "--is-shallow-repository") == "false"
    assert not (checkout / ".git/objects/info/alternates").exists()
    assert "?" not in git("rev-list", "--objects", "--missing=print", "HEAD^{tree}")
    if args.mode != "default":
        assert git("config", "remote.origin.promisor") == "true"
        assert git("config", "remote.origin.partialclonefilter") == "blob:none"
        assert "?" in git("rev-list", "--objects", "--missing=print", "HEAD~10000^{tree}")
    result.update(sha=sha, tree=tree, correctness="passed",
                  tracked_entries=len(subprocess.check_output(["git", "ls-files", "-z"], cwd=checkout).split(b"\0"))-1,
                  commits=int(git("rev-list", "--count", "HEAD")),
                  git_bytes=int(subprocess.check_output(["du", "-sb", ".git"], cwd=checkout).split()[0]),
                  worktree_bytes=int(subprocess.check_output(["du", "--exclude=.git", "-sb", "."], cwd=checkout).split()[0]))
else:
    result["correctness"] = "not validated"

output = result_dir / "result.json"
output.write_text(json.dumps(result, indent=2) + "\n")
print("BENCHMARK_RESULT " + json.dumps(result), flush=True)
subprocess.run(["buildkite-agent", "artifact", "upload", "result.json"], cwd=result_dir, check=True)
shutil.rmtree(temporary)
if return_code or abort:
    raise SystemExit(1)
