#!/usr/bin/env python3
"""Patch-cache checkout benchmark: one controlled bootstrap, upstream Git requests counted.

Runs `buildkite-agent bootstrap --phases=plugin,checkout` with Git mirrors off, as in
earlier rounds. Every Git process inherits GIT_TRACE_CURL and GIT_TRACE2_EVENT, so the
agent's own fetches, verification fetches and lazy fetches are all counted. Never runs
commands from the target repository.
"""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import time
import urllib.request

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--plugin", required=True, help="Plugin location#ref for BUILDKITE_PLUGINS")
parser.add_argument("--prefix", required=True)
parser.add_argument("--label", required=True)
parser.add_argument("--commit", required=True, help="Full SHA, or HEAD with --branch")
parser.add_argument("--branch", default="master")
parser.add_argument("--treeless", action="store_true")
parser.add_argument("--read-only", action="store_true")
parser.add_argument("--max-age", type=int)
parser.add_argument("--verification", choices=["strict", "off"], default="strict")
parser.add_argument("--agent-skip-fetch", action="store_true",
                    help="Simulate agent-level skip-fetch under checkout-override-mode strict")
parser.add_argument("--expected-tree", help="Independent tree ID; 'github' looks it up")
parser.add_argument("--publish-resolved", help="Meta-data key prefix for the resolved commit/tree")
parser.add_argument("--history-depth", type=int, default=10000,
                    help="Treeless: this ancestor's tree must stay missing")
args = parser.parse_args()

partial_filter = "tree:0" if args.treeless else "blob:none"
repo = os.environ["BUILDKITE_REPO"]
repo_path = re.sub(r"^https://[^/]+", "", repo).removesuffix(".git")
checkout = Path(os.environ["BUILDKITE_BUILD_CHECKOUT_PATH"])
result_dir = Path("/tmp") / ("git-snapshot-patch-" + os.environ["BUILDKITE_JOB_ID"])
result_dir.mkdir()
temporary = result_dir / "temporary"
temporary.mkdir()
trace2 = result_dir / "trace2.json"
curl_trace = result_dir / "curl.log"

config = {"key-prefix": args.prefix, "refresh": not args.read_only,
          "treeless": args.treeless}
if args.max_age:
    config["max-age"] = args.max_age
env = dict(os.environ, BUILDKITE_SKIP_CHECKOUT="false", TMPDIR=str(temporary),
           BUILDKITE_COMMIT=args.commit, BUILDKITE_BRANCH=args.branch,
           GIT_TRACE2_EVENT=str(trace2), GIT_TRACE_CURL=str(curl_trace),
           GIT_TRACE_CURL_NO_DATA="1",
           # Hook refreshes re-read these values; match the explicit CLI flags.
           BUILDKITE_GIT_MIRRORS_PATH="", BUILDKITE_GIT_MIRRORS_SKIP_UPDATE="true",
           BUILDKITE_GIT_SUBMODULES="false", BUILDKITE_GIT_LFS_ENABLED="false",
           BUILDKITE_GIT_COMMIT_VERIFICATION=args.verification,
           BUILDKITE_GIT_FETCH_FLAGS="-v --prune", BUILDKITE_GIT_CLONE_FLAGS="-v",
           BUILDKITE_PLUGINS=json.dumps([{args.plugin: config}]))
if args.agent_skip_fetch:
    env.update(BUILDKITE_CHECKOUT_OVERRIDE_MODE="strict", BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS="true")
inherited = {name: os.environ.get(name) for name in [
    "BUILDKITE_CHECKOUT_OVERRIDE_MODE", "BUILDKITE_GIT_SKIP_FETCH_EXISTING_COMMITS",
    "BUILDKITE_COMMAND_EVAL", "BUILDKITE_GIT_MIRRORS_PATH"]}
command = ["buildkite-agent", "bootstrap", "--phases=plugin,checkout",
           "--git-mirrors-path=", "--git-mirrors-skip-update=true",
           "--local-hooks-enabled=false", "--no-job-api",
           "--git-submodules=false", "--git-lfs-enabled=false",
           "--git-commit-verification=" + args.verification,
           "--git-clone-flags=-v", "--git-fetch-flags=-v --prune"]

# Timestamp every output line; phase boundaries come from agent and plugin lines.
start = time.monotonic()
process = subprocess.Popen(command, cwd=checkout, env=env, stdout=subprocess.PIPE,
                           stderr=subprocess.STDOUT)
lines = []
for raw in process.stdout:
    line = raw.decode(errors="replace").rstrip("\r\n")
    print(line, flush=True)
    lines.append((time.monotonic() - start, re.sub(r"\x1b\[[0-9;]*m", "", line)))
return_code = process.wait()
bootstrap_seconds = time.monotonic() - start

def first(pattern, after=0.0):
    for t, line in lines:
        if t >= after and re.search(pattern, line):
            return t, line
    return None, None

def number(pattern):
    _, line = first(pattern)
    match = re.search(pattern, line) if line else None
    return int(match.group(1)) if match else None

t_pre, _ = first(r"^\$ .*git-snapshot.*/hooks/pre-checkout$")
t_restore, restore_line = first(r"git-snapshot: restore hit=")
t_patch, patch_line = first(r"git-snapshot: patch hit=")
t_post, _ = first(r"^\$ .*/hooks/post-checkout$")
t_prepare, _ = first(r"^~~~ Preparing working directory", after=t_restore or 0.0)
timeline = [{"t": round(t, 3), "line": line} for t, line in lines if re.search(
    r"git-snapshot:|Cache restored|No cache|Restoring cache|Saving cache|Cache saved|"
    r"already exists|skipping fetch|^\$ git|^~~~ |Changes to some env vars", line)]

# Everything after the post-checkout hook starts is patch/snapshot saving.
checkout_seconds = t_post if t_post is not None else bootstrap_seconds
save_seconds = bootstrap_seconds - checkout_seconds

# Upstream requests: HTTP requests to the target repository, and the Git sessions behind them.
requests = []
if curl_trace.exists():
    for line in curl_trace.read_text(errors="replace").splitlines():
        match = re.search(r"Send header: (GET|POST) (\S+)", line)
        if match and match.group(2).startswith(repo_path):
            requests.append(match.group(1) + " " + match.group(2).split("?")[0])
processes = {}
if trace2.exists():
    for line in trace2.read_text(errors="replace").splitlines():
        event = json.loads(line)
        state = processes.setdefault(event["sid"], {})
        if event["event"] == "start":
            state["argv"] = event["argv"]
        elif event["event"] == "cmd_name":
            state["name"] = event["name"]
sessions = []
for sid, state in processes.items():
    if state.get("name") == "remote-curl" and repo in " ".join(state.get("argv", [])):
        chain = [processes.get("/".join(sid.split("/")[:i]), {}) for i in range(1, sid.count("/") + 1)]
        sessions.append({"root": chain[0].get("argv", [])[1:] if chain else [],
                         "chain": [c.get("name") for c in chain]})

result = {"label": args.label, "plugin": args.plugin, "prefix": args.prefix,
          "treeless": args.treeless, "read_only": args.read_only, "max_age": args.max_age,
          "verification": args.verification, "agent_skip_fetch": args.agent_skip_fetch,
          "requested_commit": args.commit,
          "branch": args.branch, "inherited": inherited,
          "build_url": os.environ["BUILDKITE_BUILD_URL"], "job_id": os.environ["BUILDKITE_JOB_ID"],
          "return_code": return_code, "bootstrap_seconds": bootstrap_seconds,
          "checkout_seconds": checkout_seconds, "save_seconds": save_seconds,
          "plugin_setup_and_restore_seconds": t_restore,
          "snapshot_restore_seconds": (t_restore - t_pre) if None not in (t_restore, t_pre) else None,
          "patch_restore_apply_seconds": (t_patch - t_restore) if None not in (t_patch, t_restore) else None,
          "agent_checkout_seconds": (t_post - t_prepare) if None not in (t_post, t_prepare) else None,
          "restore": restore_line, "patch": patch_line,
          "patch_hit": None if patch_line is None else "hit=true" in patch_line,
          "patch_bytes": number(r"patch hit=true .*bytes=(\d+)"),
          "snapshot_commit": (re.search(r"snapshot=([0-9a-f]{40})", patch_line or "") or [None, None])[1],
          "patch_saved_bytes": number(r"patch save bytes=(\d+)"),
          "skip_fetch_exported": any("agent skips its fetch" in l for _, l in lines),
          "agent_skipped_fetch": any("already exists locally, skipping fetch" in l for _, l in lines),
          "env_changes_blocked": [l for _, l in lines if "Changes to some env vars were blocked" in l],
          "upstream_http_requests": len(requests), "requests": requests,
          "upstream_sessions": len(sessions), "sessions": sessions,
          "git_version": subprocess.check_output(["git", "--version"], text=True).strip(),
          "agent_version": subprocess.check_output(["buildkite-agent", "--version"], text=True).strip(),
          "timeline": timeline}

def validate():
    validation_env = dict(os.environ, GIT_ALLOW_PROTOCOL="", GIT_NO_LAZY_FETCH="1")
    def git(*arguments):
        return subprocess.check_output(["git", "-c", "core.hooksPath=/dev/null", *arguments],
                                       cwd=checkout, env=validation_env, text=True).strip()
    sha = git("rev-parse", "HEAD")
    if args.commit != "HEAD":
        assert sha == args.commit, "Checked out the wrong commit"
    tree = git("rev-parse", "HEAD^{tree}")
    expected = args.expected_tree
    if expected == "github":
        api = "https://api.github.com/repos" + repo_path + "/git/commits/" + sha
        with urllib.request.urlopen(api, timeout=30) as response:
            expected = json.load(response)["tree"]["sha"]
    assert expected and tree == expected, "Independent tree differs"
    assert tree == git("write-tree")
    assert not git("status", "--porcelain")
    assert git("config", "remote.origin.url") == repo
    assert git("config", "remote.origin.promisor") == "true"
    assert git("config", "remote.origin.partialclonefilter") == partial_filter
    assert git("rev-parse", "--is-shallow-repository") == "false"
    assert not (checkout / ".git/objects/info/alternates").exists()
    assert "?" not in git("rev-list", "--objects", "--missing=print", "HEAD^{tree}")
    if args.treeless:
        # Read the raw header: even show --no-patch can load a missing tree.
        old_tree = git("cat-file", "commit", "HEAD~%d" % args.history_depth).splitlines()[0].split()[1]
        missing = subprocess.run(["git", "cat-file", "-e", old_tree], cwd=checkout,
                                 env=validation_env, capture_output=True)
        assert missing.returncode != 0, "Historical tree unexpectedly hydrated"
    result.update(sha=sha, tree=tree, expected_tree=expected, correctness="passed")
    if args.publish_resolved:
        subprocess.run(["buildkite-agent", "meta-data", "set", args.publish_resolved + "-commit", sha], check=True)
        subprocess.run(["buildkite-agent", "meta-data", "set", args.publish_resolved + "-tree", tree], check=True)

result["correctness"] = "not validated"
if return_code == 0:
    try:
        validate()
    except (AssertionError, subprocess.CalledProcessError, OSError) as error:
        result["correctness"] = "failed: %r" % error

summary = {k: result.get(k) for k in ["label", "patch", "upstream_http_requests",
           "upstream_sessions", "checkout_seconds", "save_seconds", "correctness"]}
print("PATCH_SUMMARY " + json.dumps(summary), flush=True)
(result_dir / "result.json").write_text(json.dumps(result, indent=2) + "\n")
subprocess.run(["buildkite-agent", "artifact", "upload", "result.json"], cwd=result_dir, check=True)
shutil.rmtree(temporary, ignore_errors=True)
if return_code or result["correctness"] != "passed":
    raise SystemExit(1)
