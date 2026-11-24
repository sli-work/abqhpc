#!/usr/bin/env python3
"""SQLite helpers for abqctl_queue. CLI for enqueue/list/cancel/lease/status."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path

DEFAULT_QUEUE_DIR = os.environ.get(
    "ABQCTL_QUEUE_DIR", "/public/home/tsyg/tsyg/abqctl_queue"
)


def now_iso() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def db_path(queue_dir: str | None = None) -> Path:
    root = Path(queue_dir or DEFAULT_QUEUE_DIR)
    root.mkdir(parents=True, exist_ok=True)
    return root / "queue.db"


def connect(queue_dir: str | None = None) -> sqlite3.Connection:
    path = db_path(queue_dir)
    conn = sqlite3.connect(str(path), timeout=60)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=60000")
    return conn


def init_db(queue_dir: str | None = None) -> str:
    root = Path(queue_dir or DEFAULT_QUEUE_DIR)
    root.mkdir(parents=True, exist_ok=True)
    schema = Path(__file__).resolve().parent / "schema.sql"
    sql = schema.read_text(encoding="utf-8")
    conn = connect(queue_dir)
    try:
        conn.executescript(sql)
        conn.commit()
    finally:
        conn.close()
    return str(db_path(queue_dir))


def enqueue(
    inp: str,
    cpus: int = 8,
    double_mode: str = "both",
    prefer_node: str | None = None,
    priority: int = 0,
    queue_dir: str | None = None,
) -> int:
    init_db(queue_dir)
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        cur = conn.execute(
            """
            INSERT INTO jobs (
              inp, cpus, double_mode, prefer_node, priority, status,
              created_at, updated_at, backend
            ) VALUES (?, ?, ?, ?, ?, 'waiting', ?, ?, 'direct')
            """,
            (
                inp,
                int(cpus),
                double_mode,
                prefer_node or None,
                int(priority),
                ts,
                ts,
            ),
        )
        conn.commit()
        return int(cur.lastrowid)
    finally:
        conn.close()


def list_jobs(
    status: str | None = None,
    limit: int = 200,
    queue_dir: str | None = None,
) -> list[dict]:
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        if status:
            rows = conn.execute(
                """
                SELECT * FROM jobs WHERE status = ?
                ORDER BY priority DESC, id ASC LIMIT ?
                """,
                (status, limit),
            ).fetchall()
        else:
            rows = conn.execute(
                """
                SELECT * FROM jobs
                ORDER BY
                  CASE status
                    WHEN 'running' THEN 0
                    WHEN 'starting' THEN 1
                    WHEN 'waiting' THEN 2
                    WHEN 'failed' THEN 3
                    WHEN 'done' THEN 4
                    ELSE 5
                  END,
                  priority DESC, id ASC
                LIMIT ?
                """,
                (limit,),
            ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def cancel_job(job_id: int, queue_dir: str | None = None) -> bool:
    init_db(queue_dir)
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        cur = conn.execute(
            """
            UPDATE jobs SET status='cancelled', updated_at=?, finished_at=?
            WHERE id=? AND status='waiting'
            """,
            (ts, ts, job_id),
        )
        conn.commit()
        return cur.rowcount > 0
    finally:
        conn.close()


def claim_next_job(queue_dir: str | None = None) -> dict | None:
    """Mark next waiting job as starting. Caller must hold scheduling lock."""
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            """
            SELECT * FROM jobs
            WHERE status='waiting'
            ORDER BY priority DESC, id ASC
            LIMIT 1
            """
        ).fetchone()
        if not row:
            conn.commit()
            return None
        conn.execute(
            """
            UPDATE jobs SET status='starting', updated_at=? WHERE id=?
            """,
            (ts, row["id"]),
        )
        conn.commit()
        out = dict(row)
        out["status"] = "starting"
        out["updated_at"] = ts
        return out
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def mark_running(
    job_id: int,
    node: str,
    pid: int,
    job_name: str,
    queue_dir: str | None = None,
) -> None:
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='running', node=?, pid=?, job_name=?,
              started_at=?, updated_at=?, error=NULL
            WHERE id=?
            """,
            (node, pid, job_name, ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_failed(job_id: int, error: str, queue_dir: str | None = None) -> None:
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='failed', error=?, finished_at=?, updated_at=?
            WHERE id=?
            """,
            (error[:2000], ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def mark_done(job_id: int, queue_dir: str | None = None) -> None:
    ts = now_iso()
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE jobs SET status='done', finished_at=?, updated_at=?
            WHERE id=?
            """,
            (ts, ts, job_id),
        )
        conn.commit()
    finally:
        conn.close()


def requeue_stale_starting(timeout_sec: int = 120, queue_dir: str | None = None) -> int:
    conn = connect(queue_dir)
    try:
        rows = conn.execute(
            "SELECT id, updated_at FROM jobs WHERE status='starting'"
        ).fetchall()
        n = 0
        ts = now_iso()
        for r in rows:
            try:
                updated = datetime.fromisoformat(r["updated_at"])
            except Exception:
                continue
            if datetime.now(updated.tzinfo) - updated > timedelta(seconds=timeout_sec):
                conn.execute(
                    """
                    UPDATE jobs SET status='waiting', updated_at=?, error=?
                    WHERE id=? AND status='starting'
                    """,
                    (ts, "starting timeout; requeued", r["id"]),
                )
                n += 1
        conn.commit()
        return n
    finally:
        conn.close()


def list_running_tracked(queue_dir: str | None = None) -> list[dict]:
    return list_jobs(status="running", queue_dir=queue_dir)


def upsert_node_snapshot(snap: dict, queue_dir: str | None = None) -> None:
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            INSERT INTO node_snapshots(
              node, ncpu, used_cpus, running_jobs, loadavg, detail_json, updated_at
            ) VALUES (?,?,?,?,?,?,?)
            ON CONFLICT(node) DO UPDATE SET
              ncpu=excluded.ncpu,
              used_cpus=excluded.used_cpus,
              running_jobs=excluded.running_jobs,
              loadavg=excluded.loadavg,
              detail_json=excluded.detail_json,
              updated_at=excluded.updated_at
            """,
            (
                snap["node"],
                snap.get("ncpu"),
                snap.get("used_cpus"),
                snap.get("running_jobs"),
                snap.get("loadavg"),
                json.dumps(snap.get("jobs") or [], ensure_ascii=False),
                now_iso(),
            ),
        )
        conn.commit()
    finally:
        conn.close()


def list_node_snapshots(queue_dir: str | None = None) -> list[dict]:
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        rows = conn.execute(
            "SELECT * FROM node_snapshots ORDER BY node"
        ).fetchall()
        return [dict(r) for r in rows]
    finally:
        conn.close()


def lease_status(queue_dir: str | None = None) -> dict | None:
    init_db(queue_dir)
    conn = connect(queue_dir)
    try:
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        return dict(row) if row else None
    finally:
        conn.close()


def lease_try_acquire(
    owner: str,
    lease_sec: int = 45,
    queue_dir: str | None = None,
) -> bool:
    """Acquire or steal expired lease. Returns True if this owner holds it."""
    init_db(queue_dir)
    ts = datetime.now(timezone.utc).astimezone()
    until = ts + timedelta(seconds=lease_sec)
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        if row is None:
            conn.execute(
                """
                INSERT INTO scheduler_lease(id, owner, lease_until, heartbeat_at, started_at)
                VALUES (1, ?, ?, ?, ?)
                """,
                (owner, until.isoformat(timespec="seconds"), ts.isoformat(timespec="seconds"), ts.isoformat(timespec="seconds")),
            )
            conn.commit()
            return True
        try:
            exp = datetime.fromisoformat(row["lease_until"])
        except Exception:
            exp = ts
        if row["owner"] == owner or exp <= ts:
            conn.execute(
                """
                UPDATE scheduler_lease SET owner=?, lease_until=?, heartbeat_at=?,
                  started_at=CASE WHEN owner=? THEN started_at ELSE ? END
                WHERE id=1
                """,
                (
                    owner,
                    until.isoformat(timespec="seconds"),
                    ts.isoformat(timespec="seconds"),
                    owner,
                    ts.isoformat(timespec="seconds"),
                ),
            )
            conn.commit()
            return True
        conn.commit()
        return False
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def lease_renew(owner: str, lease_sec: int = 45, queue_dir: str | None = None) -> bool:
    init_db(queue_dir)
    ts = datetime.now(timezone.utc).astimezone()
    until = ts + timedelta(seconds=lease_sec)
    conn = connect(queue_dir)
    try:
        conn.execute("BEGIN IMMEDIATE")
        row = conn.execute(
            "SELECT * FROM scheduler_lease WHERE id=1"
        ).fetchone()
        if not row or row["owner"] != owner:
            conn.commit()
            return False
        conn.execute(
            """
            UPDATE scheduler_lease SET lease_until=?, heartbeat_at=? WHERE id=1 AND owner=?
            """,
            (until.isoformat(timespec="seconds"), ts.isoformat(timespec="seconds"), owner),
        )
        conn.commit()
        return True
    except Exception:
        conn.rollback()
        raise
    finally:
        conn.close()


def lease_release(owner: str, queue_dir: str | None = None) -> None:
    conn = connect(queue_dir)
    try:
        conn.execute(
            """
            UPDATE scheduler_lease SET lease_until=? WHERE id=1 AND owner=?
            """,
            (now_iso(), owner),
        )
        conn.commit()
    finally:
        conn.close()


def _print_json(obj) -> None:
    print(json.dumps(obj, ensure_ascii=False, indent=2 if isinstance(obj, list) and len(obj) > 1 else None))


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="abqctl_queue DB CLI")
    p.add_argument("--queue-dir", default=DEFAULT_QUEUE_DIR)
    sub = p.add_subparsers(dest="cmd", required=True)

    sub.add_parser("init")

    pe = sub.add_parser("enqueue")
    pe.add_argument("inp")
    pe.add_argument("--cpus", type=int, default=8)
    pe.add_argument("--double", default="both")
    pe.add_argument("--node", default="")
    pe.add_argument("--priority", type=int, default=0)

    pl = sub.add_parser("list")
    pl.add_argument("--status", default="")
    pl.add_argument("--limit", type=int, default=200)

    pc = sub.add_parser("cancel")
    pc.add_argument("id", type=int)

    sub.add_parser("lease-status")
    sub.add_parser("nodes")

    args = p.parse_args(argv)
    qd = args.queue_dir

    if args.cmd == "init":
        print(init_db(qd))
        return 0
    if args.cmd == "enqueue":
        jid = enqueue(
            args.inp,
            cpus=args.cpus,
            double_mode=args.double,
            prefer_node=args.node or None,
            priority=args.priority,
            queue_dir=qd,
        )
        print(json.dumps({"ok": True, "id": jid}, ensure_ascii=False))
        return 0
    if args.cmd == "list":
        rows = list_jobs(status=args.status or None, limit=args.limit, queue_dir=qd)
        _print_json(rows)
        return 0
    if args.cmd == "cancel":
        ok = cancel_job(args.id, queue_dir=qd)
        print(json.dumps({"ok": ok, "id": args.id}, ensure_ascii=False))
        return 0 if ok else 1
    if args.cmd == "lease-status":
        st = lease_status(qd)
        _print_json(st or {"owner": None})
        return 0
    if args.cmd == "nodes":
        _print_json(list_node_snapshots(qd))
        return 0
    return 2


if __name__ == "__main__":
    sys.exit(main())
