"""Report Python, TOML and JSON files in the workflow configuration that do not parse."""

import json
import sys
import tomllib


def check(path):
    """Raise when the file does not parse; return None when it is fine."""
    with open(path, "rb") as handle:
        data = handle.read()
    if path.endswith(".toml"):
        tomllib.loads(data.decode("utf-8-sig"))
    elif path.endswith(".json"):
        json.loads(data.decode("utf-8-sig"))
    else:
        compile(data, path, "exec")


def main():
    failed = 0
    for path in sys.argv[1:]:
        try:
            check(path)
        except Exception as exc:
            print("FAIL\t%s\t%s" % (path, exc))
            failed = 1
    return failed


if __name__ == "__main__":
    sys.exit(main())
