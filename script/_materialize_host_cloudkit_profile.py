#!/usr/bin/env python3
"""Internal helper for build_and_run.sh; emits no credential data."""

from pathlib import Path
import sys

from host_release_credentials import CredentialError, materialize_cloudkit_profile


def main() -> int:
    if len(sys.argv) != 2:
        return 2
    try:
        return 0 if materialize_cloudkit_profile(Path(sys.argv[1])) else 3
    except CredentialError as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
