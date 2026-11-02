"""Summarise interleaved benchmark logs as a Markdown table: baseline and candidate averages per test."""
import re
import sys
from collections import defaultdict
from pathlib import Path

PATTERN = re.compile(
    r"-\[QuietFrameTests\.(\w+) (\w+)\]' measured \[([^\]]+)\] average: (-?[0-9.]+), "
    r"relative standard deviation: ([0-9.]+)%"
)


def averages(paths):
    values = defaultdict(list)
    for path in paths:
        for line in Path(path).read_text(encoding="utf-8", errors="replace").splitlines():
            match = PATTERN.search(line)
            if match:
                test = f"{match.group(1)}.{match.group(2)}"
                if not match.group(3).startswith("Clock Monotonic Time"):
                    test += f" [{match.group(3)}]"
                values[test].append(float(match.group(4)))
    return {test: sum(runs) / len(runs) for test, runs in values.items()}


def main():
    separator = sys.argv.index("--")
    baseline = averages(sys.argv[1:separator])
    candidate = averages(sys.argv[separator + 1:])
    print("Times are in seconds; other metrics name their unit after the test.")
    print()
    print("| Test | Baseline | Candidate | Candidate / baseline |")
    print("| --- | --- | --- | --- |")
    for test in sorted(set(baseline) | set(candidate)):
        before = baseline.get(test)
        after = candidate.get(test)
        ratio = f"{after / before:.2f}" if before and after else ""
        print(f"| {test} | {'' if before is None else f'{before:.4f}'} | {'' if after is None else f'{after:.4f}'} | {ratio} |")


main()
