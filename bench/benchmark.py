#!/usr/bin/env python3
"""Collect repeatable JSON measurements from an external benchmark executable.

The command must print one JSON object per invocation with:
transport, events, elapsed_ns, bytes. This runner reports supplied measurements;
it does not fabricate a transport or network benchmark.
"""
import argparse
import csv
import html
import json
import shlex
import statistics
import subprocess
from pathlib import Path

REQUIRED = {"transport", "events", "elapsed_ns", "bytes"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--command",
        required=True,
        help="Executable command returning JSON: transport, events, elapsed_ns, bytes",
    )
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--out", default="benchmark-results")
    args = parser.parse_args()
    if args.runs < 1:
        parser.error("--runs must be at least 1")
    command = shlex.split(args.command)
    if not command:
        parser.error("--command must not be empty")

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    rows = []
    for run_number in range(1, args.runs + 1):
        raw = subprocess.check_output(command, text=True, stderr=subprocess.PIPE)
        measurement = json.loads(raw)
        missing = REQUIRED - measurement.keys()
        if missing:
            raise SystemExit(f"measurement missing required fields: {', '.join(sorted(missing))}")
        for field in ("events", "elapsed_ns", "bytes"):
            if not isinstance(measurement[field], int) or measurement[field] < 0:
                raise SystemExit(f"{field} must be a non-negative integer")
        if not isinstance(measurement["transport"], str) or not measurement["transport"]:
            raise SystemExit("transport must be a non-empty string")
        if measurement["elapsed_ns"] == 0:
            raise SystemExit("elapsed_ns must be greater than zero")
        rows.append({**measurement, "run": run_number})

    fields = ["run", "transport", "events", "elapsed_ns", "bytes"]
    with (out / "results.csv").open("w", newline="", encoding="utf-8") as handle:
        writer = csv.DictWriter(handle, fieldnames=fields)
        writer.writeheader()
        writer.writerows(rows)

    grouped = {}
    for row in rows:
        grouped.setdefault(row["transport"], []).append(row)
    summaries = []
    for name, values in sorted(grouped.items()):
        elapsed = [row["elapsed_ns"] for row in values]
        events = [row["events"] for row in values]
        byte_counts = [row["bytes"] for row in values]
        median_elapsed = statistics.median(elapsed)
        median_events = statistics.median(events)
        median_bytes = statistics.median(byte_counts)
        summaries.append({
            "transport": name,
            "runs": len(values),
            "median_elapsed_ns": int(median_elapsed),
            "median_events": int(median_events),
            "median_bytes": int(median_bytes),
            "median_events_per_second": round(median_events * 1e9 / median_elapsed, 2),
            "median_bytes_per_second": round(median_bytes * 1e9 / median_elapsed, 2),
        })

    (out / "summary.json").write_text(json.dumps(summaries, indent=2), encoding="utf-8")
    rows_html = "".join(
        "<tr><td>{}</td><td>{}</td><td>{:,}</td><td>{:,.2f}</td><td>{:,.2f}</td></tr>".format(
            html.escape(item["transport"]),
            item["runs"],
            item["median_elapsed_ns"],
            item["median_events_per_second"],
            item["median_bytes_per_second"],
        )
        for item in summaries
    )
    report = """<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width">
<title>Ubiq Channels benchmark</title>
<style>
:root{color-scheme:dark}body{font:16px system-ui;background:#10131a;color:#e8edf5;margin:clamp(1rem,4vw,4rem)}
h1{letter-spacing:-.03em}p{color:#aab7c8;line-height:1.6}.panel{overflow-x:auto;border:1px solid #354052;border-radius:12px}
table{border-collapse:collapse;width:100%;min-width:680px}td,th{padding:.85rem 1rem;border-bottom:1px solid #354052;text-align:right}
td:first-child,th:first-child{text-align:left}th{color:#7dd3fc;font-weight:600;background:#171d28}
tbody tr:hover{background:#1a2230}footer{margin-top:1.5rem;color:#8492a6;font-size:.9rem}
</style></head><body><h1>Ubiq Channels benchmark</h1>
<p>Median of repeated measurements from the supplied executable. Throughput is calculated from reported event/byte counts and elapsed time. Results are only comparable when runs use equivalent payloads, workloads, and environments.</p>
<div class="panel"><table><thead><tr><th>Transport</th><th>Runs</th><th>Median elapsed (ns)</th><th>Events/s</th><th>Bytes/s</th></tr></thead>
<tbody>""" + rows_html + """</tbody></table></div>
<footer>Raw measurements: results.csv · Aggregates: summary.json</footer>
</body></html>"""
    (out / "report.html").write_text(report, encoding="utf-8")
    print(f"Reports written to {out}")


if __name__ == "__main__":
    main()
