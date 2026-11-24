#!/usr/bin/env python3
"""Load, validate and flatten the host YAML config for shell consumption.

Usage:
    config.py flatten  <host.yaml>   # emit  CFG_<path>='value'  (shell-quotable)
    config.py validate <host.yaml>   # validate only, exit non-zero on error
    config.py json <host.yaml>       # emit merged config as JSON (ansible -e)
    config.py get <host.yaml> a.b.c  # print a single resolved value

Design notes:
  * Defaults are applied HERE so the shell never has to guess.
  * Validation uses the bundled jsonschema if installed, otherwise a small
    built-in checker covering the fields the installer actually depends on.
  * Lists of scalars flatten to a space-joined string plus a <path>__count.
"""
import json
import os
import shlex
import sys

try:
    import yaml
except ImportError:  # pragma: no cover - guarded by bootstrap apt install
    sys.stderr.write(
        "error: python3 PyYAML is required. Install with: apt-get install -y python3-yaml\n"
    )
    sys.exit(3)

HERE = os.path.dirname(os.path.abspath(__file__))
SCHEMA = os.path.join(HERE, "..", "..", "config", "schema", "host.schema.json")

DEFAULTS = {
    "system": {
        "hostname": "ubuntu-desktop",
        "username": "john",
        "timezone": "Etc/UTC",
        "locale": "en_US.UTF-8",
        "release": "resolute",
        "desktop": "ubuntu",
    },
    "storage": {
        "disk": "",
        "pool_name": "rpool",
        "filesystem": "zfs",
        "pool_compatibility": "openzfs-2.2",
        "ashift": 12,
        "swap_size_mib": 2048,
        "encryption": {"enabled": False},
    },
    "boot": {
        "manager": "zfsbootmenu",
        "esp_size_mib": 512,
        "secure_boot": False,
        "kernel_cmdline": "quiet splash",
    },
    "snapshots": {
        "enabled": True,
        "before_apt": True,
        "hourly": 12,
        "daily": 7,
        "weekly": 4,
        "monthly": 3,
        "capacity_warn_percent": 80,
    },
    "provisioning": {"enabled": True, "playbook": "ansible/site.yml"},
    "features": {
        "nvidia": False,
        "flatpak": True,
        "docker": False,
        "development_tools": True,
        "chezmoi": {"enabled": False, "repo": "", "branch": "main"},
    },
}


def deep_merge(base, over):
    out = dict(base)
    for k, v in (over or {}).items():
        if isinstance(v, dict) and isinstance(out.get(k), dict):
            out[k] = deep_merge(out[k], v)
        else:
            out[k] = v
    return out


def load(path):
    with open(path, "r", encoding="utf-8") as fh:
        raw = yaml.safe_load(fh) or {}
    if not isinstance(raw, dict):
        raise SystemExit("error: config root must be a mapping")
    return deep_merge(DEFAULTS, raw)


def validate(cfg):
    errors = []
    # Prefer jsonschema when available for complete coverage.
    try:
        import jsonschema  # type: ignore

        with open(SCHEMA, encoding="utf-8") as fh:
            schema = json.load(fh)
        v = jsonschema.Draft202012Validator(schema)
        errors = [f"{'/'.join(map(str, e.path))}: {e.message}" for e in v.iter_errors(cfg)]
    except ImportError:
        # Minimal built-in checks for the load-bearing fields.
        disk = cfg["storage"]["disk"]
        if not disk or "REPLACE_ME" in disk:
            errors.append("storage.disk: must be set to a real /dev/disk/by-id/ path")
        if cfg["storage"]["filesystem"] != "zfs":
            errors.append("storage.filesystem: only 'zfs' is supported")
        if cfg["boot"]["manager"] != "zfsbootmenu":
            errors.append("boot.manager: only 'zfsbootmenu' is supported")
        hn = cfg["system"]["hostname"]
        if not hn or " " in hn:
            errors.append("system.hostname: invalid")
    # Always-on cross checks regardless of validator.
    if cfg["storage"]["disk"] and not cfg["storage"]["disk"].startswith("/dev/"):
        errors.append("storage.disk: must be an absolute /dev path")
    return errors


def flatten(cfg, prefix="CFG"):
    lines = []

    def emit(path, value):
        # prefix joins to the first level with a single '_', deeper levels '__'
        key = prefix + ("_" + "__".join(path) if path else "")
        if isinstance(value, bool):
            lines.append(f"{key}={'true' if value else 'false'}")
        elif isinstance(value, (int, float, str)):
            lines.append(f"{key}={shlex.quote(str(value))}")
        elif isinstance(value, list):
            scalars = [str(x) for x in value]
            lines.append(f"{key}={shlex.quote(' '.join(scalars))}")
            lines.append(f"{key}__count={len(scalars)}")
        elif isinstance(value, dict):
            for k, v in value.items():
                emit(path + [k], v)
        elif value is None:
            lines.append(f"{key}=''")

    emit([], cfg)
    return "\n".join(lines)


def get(cfg, dotted):
    cur = cfg
    for part in dotted.split("."):
        if not isinstance(cur, dict) or part not in cur:
            raise SystemExit(f"error: no such key: {dotted}")
        cur = cur[part]
    if isinstance(cur, bool):
        return "true" if cur else "false"
    return str(cur)


def main(argv):
    if len(argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    cmd, path = argv[1], argv[2]
    cfg = load(path)
    errs = validate(cfg)
    if cmd == "validate":
        if errs:
            sys.stderr.write("config validation failed:\n")
            for e in errs:
                sys.stderr.write(f"  - {e}\n")
            return 1
        print("ok")
        return 0
    if errs:
        sys.stderr.write("config validation failed:\n")
        for e in errs:
            sys.stderr.write(f"  - {e}\n")
        return 1
    if cmd == "flatten":
        print(flatten(cfg))
        return 0
    if cmd == "json":
        print(json.dumps(cfg, indent=2, sort_keys=True))
        return 0
    if cmd == "get":
        if len(argv) < 4:
            sys.stderr.write("usage: config.py get <file> <dotted.key>\n")
            return 2
        print(get(cfg, argv[3]))
        return 0
    sys.stderr.write(f"unknown command: {cmd}\n")
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
