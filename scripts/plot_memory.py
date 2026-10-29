#!/usr/bin/env python3
"""Generate memory-usage graphs from a run-leak-investigation.sh report dir."""

from __future__ import annotations

import gzip
import re
from datetime import datetime, timezone
from pathlib import Path

import click
import matplotlib

matplotlib.use("Agg")
import matplotlib.pyplot as plt


def load_mem_log(path: Path) -> list[tuple[float, float]]:
    """Return list of (epoch_seconds, MiB)."""
    samples: list[tuple[float, float]] = []
    try:
        with path.open() as f:
            for line in f:
                parts = line.split()
                if len(parts) != 2:
                    continue
                ts, kb = float(parts[0]), float(parts[1])
                samples.append((ts, kb / 1024.0))
    except FileNotFoundError:
        pass
    return samples


def _open_log(path: Path):
    """Open a log file transparently, supporting a gzip-compressed sibling.

    Large app.log files from big runs are gzipped after the fact to keep the
    repo size down, so accept either app.log or app.log.gz.
    """
    if path.exists():
        return path.open()
    gz_path = path.with_name(path.name + ".gz")
    if gz_path.exists():
        return gzip.open(gz_path, "rt")
    raise FileNotFoundError(path)


def load_completions_utc(app_log: Path) -> list[float]:
    """Return sorted epoch seconds (UTC) for each successfully processed archive."""
    pattern = re.compile(
        r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2},\d{3}).*Successfully processed cluster"
    )
    out: list[float] = []
    with _open_log(app_log) as f:
        for line in f:
            match = pattern.match(line)
            if match:
                dt = datetime.strptime(match.group(1), "%Y-%m-%d %H:%M:%S,%f")
                dt = dt.replace(tzinfo=timezone.utc)
                out.append(dt.timestamp())
    out.sort()
    return out


def nearest_value(samples: list[tuple[float, float]], ts: float) -> float | None:
    """Return value of the first sample at/after ts, or the last sample before ts."""
    best = None
    for sample_ts, sample_value in samples:
        if sample_ts >= ts:
            return sample_value
        best = sample_value
    return best


@click.command(
    help="Generate memory graphs from a run-leak-investigation.sh report directory."
)
@click.argument(
    "report_dir",
    type=click.Path(exists=True, file_okay=False, path_type=Path),
)
@click.argument(
    "output_dir",
    required=False,
    type=click.Path(file_okay=False, path_type=Path),
)
def main(report_dir: Path, output_dir: Path | None) -> None:
    """CLI entrypoint."""
    out_dir = output_dir or report_dir

    rss_samples = load_mem_log(report_dir / "memory.log")
    stats_samples = load_mem_log(report_dir / "memory_podman_stats.log")
    has_stats = len(stats_samples) > 0

    if not rss_samples:
        click.echo("ERROR: no RSS samples found", err=True)
        raise click.exceptions.Exit(1)

    t0 = rss_samples[0][0]

    # ---- Graph 1: time (seconds since start) vs memory ----
    rss_t = [(ts - t0) for ts, _ in rss_samples]
    rss_v = [value for _, value in rss_samples]

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
        stats_v = [value for _, value in stats_samples]
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
    out1 = out_dir / "memory_vs_time.png"
    fig.savefig(out1, dpi=150)
    click.echo(f"Wrote {out1}")

    # ---- Graph 2: processed archive index vs memory ----
    completions = load_completions_utc(report_dir / "app.log")
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
        out2 = out_dir / "memory_vs_processed_archives.png"
        fig2.savefig(out2, dpi=150)
        click.echo(f"Wrote {out2}")
    else:
        click.echo(
            "WARNING: no 'Successfully processed cluster' lines found in app.log; skipping graph 2",
            err=True,
        )


if __name__ == "__main__":
    main()
