#!/usr/bin/env python3
"""Dependency-free Conventional Commit header checks for Git hooks and CI."""

import argparse
from pathlib import Path
import re
import subprocess
import sys

HEADER = re.compile(
    r"^(feat|fix|docs|style|refactor|perf|test|build|ci|chore|revert)"
    r"(\([a-z0-9][a-z0-9._/-]*\))?(!)?: \S.*$"
)


def valid_header(header):
    return len(header) <= 100 and HEADER.fullmatch(header) is not None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    source = parser.add_mutually_exclusive_group(required=True)
    source.add_argument("--message-file", type=Path)
    source.add_argument("--title")
    source.add_argument("--range", dest="revision_range")
    args = parser.parse_args()
    if args.message_file:
        lines = args.message_file.read_text().splitlines()
        headers = [lines[0] if lines else ""]
    elif args.title is not None:
        headers = [args.title]
    else:
        result = subprocess.run(
            ["git", "log", "--no-merges", "--format=%s", args.revision_range],
            check=True, capture_output=True, text=True,
        )
        headers = result.stdout.splitlines()
    invalid = [header for header in headers if not valid_header(header)]
    if invalid:
        for header in invalid:
            print(f"Invalid Conventional Commit header: {header!r}", file=sys.stderr)
        print("Use type(scope): description, at most 100 characters. Example: fix(core): check the receiver before releasing the keyboard", file=sys.stderr)
        return 1
    print(f"Checked {len(headers)} Conventional Commit header(s).")
    return 0


if __name__ == "__main__":
    sys.exit(main())
