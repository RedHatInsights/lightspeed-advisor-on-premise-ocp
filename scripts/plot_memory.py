#!/usr/bin/env python3
"""Generate memory-usage graphs (time-based and archive-count-based) from a
run-leak-investigation.sh report directory.

Usage:
    python plot_memory.py <report_dir> [output_dir]
"""

import gzip
import os
import re
import sys
from datetime import datetime, timezone

import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_mem_log(path):
    """Return list of (epoch_seconds, mib)."""
    samples = []
    try:
        with open(path) as f:
            for line in f:
                parts = line.split()
                if len(parts) != 2:
                    continue
                ts, kb = float(parts[0]), float(parts[1])
                samples.append((ts, kb / 1024.0))
    except FileNotFoundError:
        pass
    return samples


def _open_log(path):
    """Open a log file transparently, supporting a gzip-compressed sibling
    (e.g. app.log.gz) if the plain file doesn't exist — large app.log files
    from big runs are gzipped after the fact to keep the repo size down."""
    if os.path.exists(path):
        return open(path)
    if os.path.exists(path + ".gz"):
        return gzip.open(path + ".gz", "rt")
    raise FileNotFoundError(path)


def load_completions_utc(app_log):
    """Return sorted list of epoch seconds (UTC) for each successfully
    processed archive, in completion order."""
    pattern = re.compile(
        r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}).*Successfully processed cluster"
    )
    out = []
    with _open_log(app_log) as f:
        for line in f:
            m = pattern.match(line)
            if m:
                dt = datetime.strptime(m.group(1), "%Y-%m-%d %H:%M:%S,%f")
                dt = dt.replace(tzinfo=timezone.utc)
                out.append(dt.timestamp())
    out.sort()
    return out


def nearest_value(samples, ts):
    """samples: sorted list of (epoch, value). Return value of the first
    sample at or after ts (falls back to the last sample before ts)."""
    best = None
    for s_ts, s_val in samples:
        if s_ts >= ts:
            return s_val
        best = s_val
    return best


def main():
    report_dir = sys.argv[1].rstrip("/")
    out_dir = sys.argv[2] if len(sys.argv) > 2 else report_dir

    rss_samples = load_mem_log(f"{report_dir}/memory.log")
    stats_samples = load_mem_log(f"{report_dir}/memory_podman_stats.log")
    has_stats = len(stats_samples) > 0

    if not rss_samples:
        print("ERROR: no RSS samples found", file=sys.stderr)
        sys.exit(1)

    t0 = rss_samples[0][0]

    # ---- Graph 1: time (seconds since start) vs memory ----
    rss_t = [(ts - t0) for ts, _ in rss_samples]
    rss_v = [v for _, v in rss_samples]

    fig, ax = plt.subplots(figsize=(11, 6))
    ax.plot(
        rss_t,
        rss_v,
        label="Process RSS (/proc/<pid>/status)",
        color="#1f77b4",
        linewidth=1.5,
    )
    if has_stats:
        stats_t = [(ts - t0) for ts, _ in stats_samples]
        stats_v = [v for _, v in stats_samples]
        ax.plot(
            stats_t,
            stats_v,
            label="Container memory (podman stats)",
            color="#d62728",
            linewidth=1.5,
            alpha=0.85,
        )
    ax.set_xlabel("Time since start (seconds)")
    ax.set_ylabel("Memory (MiB)")
    ax.set_title(
        f"Memory usage over time — real archive processing ({len(rss_samples)} samples)"
    )
    ax.grid(True, linestyle="--", alpha=0.4)
    ax.legend(loc="lower right")
    fig.tight_layout()
    out1 = f"{out_dir}/memory_vs_time.png"
    fig.savefig(out1, dpi=150)
    print(f"Wrote {out1}")

    # ---- Graph 2: processed archive index vs memory ----
    completions = load_completions_utc(f"{report_dir}/app.log")
    if completions:
        idx = list(range(1, len(completions) + 1))
        rss_by_archive = [nearest_value(rss_samples, ts) for ts in completions]
        fig2, ax2 = plt.subplots(figsize=(11, 6))
        ax2.plot(
            idx,
            rss_by_archive,
            label="Process RSS (/proc/<pid>/status)",
            color="#1f77b4",
            linewidth=1.5,
        )
        if has_stats:
            stats_by_archive = [nearest_value(stats_samples, ts) for ts in completions]
            ax2.plot(
                idx,
                stats_by_archive,
                label="Container memory (podman stats)",
                color="#d62728",
                linewidth=1.5,
                alpha=0.85,
            )
        ax2.set_xlabel("Processed archives (count)")
        ax2.set_ylabel("Memory (MiB)")
        ax2.set_title(
            "Memory usage vs. number of archives processed "
            f"(real processing, {len(completions)} archives)"
        )
        ax2.grid(True, linestyle="--", alpha=0.4)
        ax2.legend(loc="lower right")
        fig2.tight_layout()
        out2 = f"{out_dir}/memory_vs_processed_archives.png"
        fig2.savefig(out2, dpi=150)
        print(f"Wrote {out2}")
    else:
        print(
            "WARNING: no 'Successfully processed cluster' lines found in app.log; skipping graph 2",
            file=sys.stderr,
        )


if __name__ == "__main__":
    main()
