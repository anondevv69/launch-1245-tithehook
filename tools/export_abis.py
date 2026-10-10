#!/usr/bin/env python3
"""Export/verify standard ABI arrays from the pinned Foundry build, without dependencies."""

import argparse
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if exports differ from the build")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    destination = root / "docs" / "abi"
    destination.mkdir(parents=True, exist_ok=True)
    for name in ("TitheToken", "TitheHook", "TitheRouter"):
        result = subprocess.run(
            ["forge", "inspect", name, "abi", "--json"],
            cwd=root, check=True, capture_output=True, text=True,
        )
        abi = json.loads(result.stdout)
        path = destination / (name + ".json")
        if args.check:
            if not path.exists() or json.loads(path.read_text()) != abi:
                raise SystemExit("ABI export differs: " + str(path.relative_to(root)))
            print("Verified " + str(path.relative_to(root)))
        else:
            path.write_text(json.dumps(abi, indent=2) + "\n")
            print("Exported " + str(path.relative_to(root)))


if __name__ == "__main__":
    main()
