import sys

import yaml

path = sys.argv[1] if len(sys.argv) > 1 else "build.yaml"
with open(path) as f:
    data = yaml.safe_load(f) or {}

for item in data.get("include", []):
    print(
        "\t".join(
            [
                item.get("board", ""),
                item.get("shield", ""),
                item.get("artifact-name", ""),
                item.get("snippet", ""),
                item.get("cmake-args", ""),
            ]
        )
    )
