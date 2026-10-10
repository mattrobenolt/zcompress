"""Instance-keyed host facts."""

import json
import tempfile
from pathlib import Path
from typing import Any

from ec2bench.box import Box

TOPOLOGY = """for d in /sys/devices/system/cpu/cpu[0-9]*; do
  test ! -f "$d/online" || test "$(cat "$d/online")" = 1 || continue
  n=${d##*cpu}
  printf '%s %s %s %s\\n' "$n" "$(cat "$d/topology/physical_package_id")" \
    "$(cat "$d/topology/core_id")" "$(cat "$d/topology/thread_siblings_list")"
done"""
IDENTITY = """token=$(curl --fail --silent --max-time 5 -X PUT \
  -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' \
  http://169.254.169.254/latest/api/token) &&
curl --fail --silent --max-time 5 -H "X-aws-ec2-metadata-token: $token" \
  http://169.254.169.254/latest/dynamic/instance-identity/document"""


def topology(text: str) -> list[dict[str, Any]]:
    result = []
    for line in text.splitlines():
        cpu, package, core, siblings = line.split()
        result.append(
            {"cpu": int(cpu), "package": int(package), "core": int(core), "siblings": siblings}
        )
    return result


def collect(box: Box, results_dir: Path) -> dict[str, Any]:
    path = results_dir / ".facts" / f"{box.instance_id}.json"
    if path.exists():
        return json.loads(path.read_text())
    facts: dict[str, Any] = {"instance_id": box.instance_id, "errors": {}}
    for name, command in {
        "cpuinfo": "cat /proc/cpuinfo",
        "lscpu": "lscpu -J",
        "topology": TOPOLOGY,
        "uname": "uname -a",
        "cmdline": "cat /proc/cmdline",
        "identity": IDENTITY,
        "image_version": "cat /etc/bench-image",
        "nixos_version": "nixos-version",
    }.items():
        try:
            value = box.run(command).strip()
            facts[name] = (
                topology(value)
                if name == "topology"
                else (json.loads(value) if name in {"lscpu", "identity"} else value)
            )
        except Exception as error:  # noqa: BLE001 — host probes are optional
            facts[name] = None
            facts["errors"][name] = str(error)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        handle.write(json.dumps(facts, indent=2) + "\n")
        temporary = Path(handle.name)
    temporary.replace(path)
    return facts
