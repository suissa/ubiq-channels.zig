#!/usr/bin/env python3
"""Repeat a supplied transport benchmark command and emit CSV/HTML reports."""
import argparse, csv, html, json, statistics, subprocess
from pathlib import Path

def main():
    p = argparse.ArgumentParser()
    p.add_argument("--command", required=True, help="Command returning JSON with transport, events, elapsed_ns, bytes")
    p.add_argument("--runs", type=int, default=7)
    p.add_argument("--out", default="benchmark-results")
    a = p.parse_args()
    out = Path(a.out); out.mkdir(parents=True, exist_ok=True)
    rows = []
    for i in range(a.runs):
        row = json.loads(subprocess.check_output(a.command, shell=True, text=True))
        row["run"] = i + 1
        rows.append(row)
    fields = sorted({k for row in rows for k in row})
    with (out / "results.csv").open("w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=fields); w.writeheader(); w.writerows(rows)
    grouped = {}
    for row in rows: grouped.setdefault(row["transport"], []).append(row)
    summaries = []
    for name, values in sorted(grouped.items()):
        elapsed = [int(v["elapsed_ns"]) for v in values]
        count = int(statistics.mean(int(v["events"]) for v in values))
        median_ns = int(statistics.median(elapsed))
        summaries.append({"transport": name, "runs": len(values), "median_elapsed_ns": median_ns,
                          "mean_events": count, "median_events_per_second": round(count * 1e9 / max(1, median_ns), 2)})
    (out / "summary.json").write_text(json.dumps(summaries, indent=2))
    rows_html = "".join("<tr><td>{}</td><td>{}</td><td>{}</td><td>{}</td></tr>".format(
        html.escape(s["transport"]), s["runs"], s["median_elapsed_ns"], s["median_events_per_second"]) for s in summaries)
    (out / "report.html").write_text("""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Ubiq Channels benchmark</title><style>body{font:16px system-ui;background:#10131a;color:#e8edf5;margin:3rem}table{border-collapse:collapse;width:100%}td,th{padding:.8rem;border-bottom:1px solid #354052;text-align:left}th{color:#7dd3fc}</style><h1>Ubiq Channels benchmark</h1><p>Measured runs supplied by the benchmark command; no synthetic results.</p><table><thead><tr><th>Transport</th><th>Runs</th><th>Median elapsed (ns)</th><th>Median events/s</th></tr></thead><tbody>""" + rows_html + "</tbody></table></html>")
    print(f"Reports written to {out}")
if __name__ == "__main__": main()
