#!/usr/bin/env python3
"""Scan a login node for Abaqus processes and resource summary."""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path


JOB_RE = re.compile(
    r"(?:analysis\.pyc\s+-job\s+|job=|/|eliT_DriverLM\s+-job\s+)([A-Za-z0-9_.-]+)",
    re.I,
)
CPUS_RE = re.compile(r"\bcpus[= ](\d+)", re.I)


def run(cmd: list[str], timeout: int = 30) -> str:
    try:
        p = subprocess.run(
            cmd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=timeout,
            check=False,
        )
        return p.stdout or ""
    except Exception:
        return ""


def hostname() -> str:
    return run(["hostname"]).strip() or "unknown"


def nproc() -> int:
    out = run(["nproc"]).strip()
    try:
        return int(out)
    except Exception:
        return 1


def loadavg() -> str:
    try:
        return Path("/proc/loadavg").read_text(encoding="utf-8").split()[0]
    except Exception:
        return ""


def mem_available_mb() -> int | None:
    try:
        for line in Path("/proc/meminfo").read_text(encoding="utf-8").splitlines():
            if line.startswith("MemAvailable:"):
                kb = int(line.split()[1])
                return kb // 1024
    except Exception:
        pass
    return None


def parse_jobs_from_ps(ps_text: str) -> list[dict]:
    jobs: dict[str, dict] = {}
    for line in ps_text.splitlines():
        line = line.strip()
        if not line:
            continue
        if not any(
            k in line
            for k in ("explicit_dp", "analysis.pyc", "eliT_DriverLM", "abaqus")
        ):
            continue
        if "abqctl" in line or "abqctl_scheduler" in line:
            continue
        parts = line.split(None, 1)
        if len(parts) < 2:
            continue
        try:
            pid = int(parts[0])
        except ValueError:
            continue
        cmd = parts[1]
        m = JOB_RE.search(cmd)
        job = m.group(1) if m else f"pid{pid}"
        cm = CPUS_RE.search(cmd)
        cpus = int(cm.group(1)) if cm else 1
        # explicit_dp often one process per job; keep max cpus estimate
        prev = jobs.get(job)
        if prev is None or cpus > prev.get("cpus", 0):
            jobs[job] = {
                "job_name": job,
                "pid": pid,
                "cpus": cpus,
                "cmd": cmd[:240],
            }
    return list(jobs.values())


def scan_local() -> dict:
    # PID CMD
    ps = run(["ps", "-eo", "pid=,args="])
    jobs = parse_jobs_from_ps(ps)
    used = sum(int(j.get("cpus") or 1) for j in jobs)
    return {
        "node": hostname(),
        "ncpu": nproc(),
        "used_cpus": used,
        "running_jobs": len(jobs),
        "loadavg": loadavg(),
        "mem_available_mb": mem_available_mb(),
        "jobs": jobs,
    }


def scan_remote(node: str) -> dict:
    """Scan via ssh to node (BatchMode). Falls back to empty on failure."""
    script = (
        "python3 - <<'PY'\n"
        + Path(__file__).read_text(encoding="utf-8")
        + "\nprint(__import__('json').dumps(scan_local(), ensure_ascii=False))\nPY"
    )
    # Simpler: invoke this file remotely if deployed
    remote_py = os.environ.get(
        "ABQCTL_NODE_SCAN_PY",
        "/public/home/tsyg/tsyg/abqctl_queue/abqctl_node_scan.py",
    )
    cmd = [
        "ssh",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=8",
        "-o",
        "StrictHostKeyChecking=no",
        node,
        f"python3 {remote_py} --local --json",
    ]
    out = run(cmd, timeout=40).strip()
    if not out:
        return {
            "node": node,
            "ncpu": 0,
            "used_cpus": 0,
            "running_jobs": 0,
            "loadavg": "",
            "jobs": [],
            "error": "ssh_scan_failed",
        }
    try:
        # last JSON line
        line = out.strip().splitlines()[-1]
        data = json.loads(line)
        data["node"] = data.get("node") or node
        return data
    except Exception as e:
        return {
            "node": node,
            "ncpu": 0,
            "used_cpus": 0,
            "running_jobs": 0,
            "loadavg": "",
            "jobs": [],
            "error": str(e),
            "raw": out[-500:],
        }


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser()
    p.add_argument("node", nargs="?", default="local")
    p.add_argument("--local", action="store_true")
    p.add_argument(
        "--nodes",
        default=os.environ.get("ABQCTL_NODES", "login05 login08 login10"),
    )
    args = p.parse_args(argv)

    if args.local or args.node in ("", "local", "."):
        print(json.dumps(scan_local(), ensure_ascii=False))
        return 0

    if args.node == "all":
        result = []
        me = hostname()
        for n in args.nodes.split():
            if n == me or n in me:
                result.append(scan_local())
            else:
                result.append(scan_remote(n))
        print(json.dumps(result, ensure_ascii=False))
        return 0

    me = hostname()
    if args.node == me or args.node in me:
        print(json.dumps(scan_local(), ensure_ascii=False))
    else:
        print(json.dumps(scan_remote(args.node), ensure_ascii=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
