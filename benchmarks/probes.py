#!/usr/bin/env python3
"""Read-only Git history probes; each gets an independent object-store copy."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--checkout", type=Path, required=True)
parser.add_argument("--path", required=True)
parser.add_argument("--output", type=Path, required=True)
parser.add_argument("--timeout", type=int, default=300)
args = parser.parse_args()
git = ["git", "-c", "core.hooksPath=/dev/null", "-c", "gc.auto=0",
       "-c", "fetch.recurseSubmodules=false"]
results = []
with tempfile.TemporaryDirectory(prefix="git-history-probes-") as scratch:
    for name, commands in [
        ("diff-50", [["merge-base", "HEAD~50", "HEAD"],
                     ["diff", "--name-only", "HEAD~50..HEAD"]]),
        ("diff-500", [["merge-base", "HEAD~500", "HEAD"],
                      ["diff", "--name-only", "HEAD~500..HEAD"]]),
        ("log-path", [["log", "--format=%H", "-n", "50", "--", args.path]]),
    ]:
        target = Path(scratch) / name
        target.mkdir()
        # Hardlink existing immutable packs, not directories. Lazy fetches write
        # new packs only here; no source object store is warmed by another probe.
        shutil.copytree(args.checkout / ".git", target / ".git", copy_function=os.link)
        (target / ".git/index").unlink(missing_ok=True)
        trace = Path(scratch) / (name + ".trace")
        env = dict(os.environ, GIT_TRACE2_EVENT=str(trace))
        records = []
        for command in commands:
            start = time.monotonic()
            process = subprocess.Popen(git + command, cwd=target, env=env,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                       start_new_session=True)
            timed_out = False
            try:
                stdout, stderr = process.communicate(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                os.killpg(process.pid, signal.SIGTERM)
                try:
                    stdout, stderr = process.communicate(timeout=10)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGKILL)
                    stdout, stderr = process.communicate()
            records.append({"argv": command, "seconds": time.monotonic() - start,
                            "return_code": process.returncode, "timed_out": timed_out,
                            "stdout_sha256": hashlib.sha256(stdout).hexdigest(),
                            "stdout_lines": len(stdout.splitlines()),
                            "stderr_tail": stderr.decode(errors="replace")[-1000:]})
            if process.returncode:
                break
        fetches = sum(1 for line in trace.read_text().splitlines()
                      if (e := json.loads(line)).get("event") == "cmd_name"
                      and e.get("name") == "fetch") if trace.exists() else 0
        results.append({"probe": name, "path": args.path, "commands": records,
                        "fetch_invocations": fetches})
        print(json.dumps(results[-1]), flush=True)
        shutil.rmtree(target)
args.output.write_text(json.dumps(results, indent=2) + "\n")
