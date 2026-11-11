#!/usr/bin/env python3
"""Paired A/B statistics for scripts/bench/ab.sh.

usage: stats.py OBS.tsv [--margin METRIC=VALUE ...]

OBS.tsv has one observation per line: pair, order (AB or BA), metric, unit,
A's value, B's value. For each metric this prints the paired difference
B - A: its mean with a 95% t interval, and its median with a 95% bootstrap
interval (5000 resamples, fixed seed), and the one-sided 95% upper bound of
B's degradation (B - A for costs, A - B for rates: a unit with "/s" or
IOPS is a rate). The verdict is the median's: one pair run during a burst
of host load moves the mean by microseconds and leaves the median (the
analysis is fixed here, before any run). It follows C_TO_BEND.md's
contract:

  faster        the upper bound of degradation is at most zero
  slower        the lower bound of degradation is above zero
  inconclusive  the interval spans both
  equivalent    (only with --margin) inconclusive, but the upper bound of
                degradation is at most the margin (no worse than it, however
                much faster it may be): a pass
A later --margin for the same metric wins.

Exit status: 0 when no metric is slower, 1 when one is, 2 on bad input.
"""
import math, random, statistics, sys

def t95(df, two_sided):
    # Student's t quantile (0.95 one-sided, 0.975 two-sided) by the
    # Cornish-Fisher expansion; within 0.01 of the table for df >= 3
    z = 1.959964 if two_sided else 1.644854
    if df <= 0:
        return float("inf")
    return (z + (z**3 + z) / (4 * df) + (5 * z**5 + 16 * z**3 + 3 * z) / (96 * df**2)
            + (3 * z**7 + 19 * z**5 + 17 * z**3 - 15 * z) / (384 * df**3))

def boot_median(d, q_lo, q_hi):
    # percentile bootstrap of the median, fixed seed: the same data give the
    # same interval
    rng = random.Random(1)
    n = len(d)
    ms = sorted(statistics.median(rng.choice(d) for _ in range(n)) for _ in range(5000))
    return ms[int(q_lo * (len(ms) - 1))], ms[int(q_hi * (len(ms) - 1))]

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
    print("%-18s %3s %9s %9s %9s %21s %9s %21s %9s  %s" % ("metric", "n", "A median", "B median", "B-A mean", "95% CI (t)", "B-A med", "95% CI (bootstrap)", "degr.ub", "verdict"))
    for (m, unit), ps in sorted(by.items()):
        n = len(ps)
        d = [b - a for a, b in ps]
        mean = statistics.fmean(d)
        se = statistics.stdev(d) / math.sqrt(n) if n > 1 else float("inf")
        lo2, hi2 = mean - t95(n - 1, True) * se, mean + t95(n - 1, True) * se
        med = statistics.median(d)
        blo, bhi = boot_median(d, 0.025, 0.975) if n > 1 else (float("-inf"), float("inf"))
        b5, b95 = boot_median(d, 0.05, 0.95) if n > 1 else (float("-inf"), float("inf"))
        sign = -1 if is_rate(unit) else 1
        # degradation bounds (one-sided 95%) from the median's bootstrap
        ub = b95 if sign > 0 else -b5
        lb = b5 if sign > 0 else -b95
        if ub <= 0:
            v = "faster"
        elif lb > 0:
            v = "SLOWER"; worst = 1
        else:
            v = "inconclusive"
            if m in margins and ub <= margins[m]:
                v = "equivalent (±%g)" % margins[m]
        print("%-18s %3d %9.4g %9.4g %+9.3g [%+9.3g,%+9.3g] %+9.3g [%+9.3g,%+9.3g] %+9.3g  %s %s" % (
            m, n, statistics.median(a for a, _ in ps), statistics.median(b for _, b in ps),
            mean, lo2, hi2, med, blo, bhi, ub, v, unit))
    return worst

if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
