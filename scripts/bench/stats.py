#!/usr/bin/env python3
"""Paired A/B statistics for scripts/bench/ab.sh.

usage: stats.py OBS.tsv [--margin METRIC=VALUE ...]

OBS.tsv has one observation per line: pair, order (AB or BA), metric, unit,
A's value, B's value. For each metric this prints the paired difference
B - A, a 95% two-sided interval of its mean, and the one-sided 95% upper
bound of B's degradation (B - A for costs, A - B for rates: a unit with
"/s" or IOPS is a rate). The verdict follows C_TO_BEND.md's contract:

  faster        the upper bound of degradation is at most zero
  slower        the lower bound of degradation is above zero
  inconclusive  the interval spans both
  equivalent    (only with --margin) inconclusive, but the interval of
                degradation lies inside [-margin, +margin]

Exit status: 0 when no metric is slower, 1 when one is, 2 on bad input.
"""
import math, statistics, sys

def t95(df, two_sided):
    # Student's t quantile (0.95 one-sided, 0.975 two-sided) by the
    # Cornish-Fisher expansion; within 0.01 of the table for df >= 3
    z = 1.959964 if two_sided else 1.644854
    if df <= 0:
        return float("inf")
    return (z + (z**3 + z) / (4 * df) + (5 * z**5 + 16 * z**3 + 3 * z) / (96 * df**2)
            + (3 * z**7 + 19 * z**5 + 17 * z**3 - 15 * z) / (384 * df**3))

def is_rate(unit):
    return "/s" in unit or unit == "IOPS"

def main(argv):
    if not argv:
        print(__doc__); return 2
    margins = {}
    args = argv[1:]
    while args:
        if args[0] == "--margin" and len(args) > 1:
            k, _, v = args[1].partition("="); margins[k] = float(v); args = args[2:]
        else:
            print("stats.py: unknown argument", args[0]); return 2
    by = {}
    for line in open(argv[0]):
        f = line.rstrip("\n").split("\t")
        if len(f) != 6 or f[0] == "pair":
            continue
        _, _, m, unit, a, b = f
        try:
            by.setdefault((m, unit), []).append((float(a), float(b)))
        except ValueError:
            print("stats.py: bad value in", line.strip()); return 2
    if not by:
        print("stats.py: no observations"); return 2
    worst = 0
    print("%-20s %4s %10s %10s %9s %22s %9s  %s" % ("metric", "n", "A median", "B median", "B-A mean", "95% CI of B-A", "degr.ub", "verdict"))
    for (m, unit), ps in sorted(by.items()):
        n = len(ps)
        d = [b - a for a, b in ps]
        mean = statistics.fmean(d)
        se = statistics.stdev(d) / math.sqrt(n) if n > 1 else float("inf")
        lo2, hi2 = mean - t95(n - 1, True) * se, mean + t95(n - 1, True) * se
        sign = -1 if is_rate(unit) else 1
        g = sign * mean                      # degradation, mean
        ub = g + t95(n - 1, False) * se      # one-sided 95% upper bound
        lb = g - t95(n - 1, False) * se
        if ub <= 0:
            v = "faster"
        elif lb > 0:
            v = "SLOWER"; worst = 1
        else:
            v = "inconclusive"
            if m in margins and -margins[m] <= lb and ub <= margins[m]:
                v = "equivalent (±%g)" % margins[m]
        print("%-20s %4d %10.4g %10.4g %+9.3g [%+9.3g, %+9.3g] %+9.3g  %s %s" % (
            m, n, statistics.median(a for a, _ in ps), statistics.median(b for _, b in ps),
            mean, lo2, hi2, ub, v, unit))
    return worst

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
