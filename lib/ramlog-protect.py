#!/usr/bin/env python3
"""Stage a fail-closed patch for the known Armbian ramlog shell implementation.

The caller owns backups, bash syntax validation, and installation. This tool
never executes ramlog, changes services, or installs its staged output.
"""

import argparse
import os
from pathlib import Path
import re
import sys
import tempfile


MARKER = "flashprotect: no persistent log synchronization"


def patch_ramlog(source):
    if "\x00" in source or "\r" in source:
        raise ValueError("ramlog must be an LF-terminated shell script without NUL bytes")
    if not re.match(r"\A#!/(?:usr/)?bin/(?:env bash|bash)\n", source):
        raise ValueError("unsupported ramlog interpreter; expected a Bash script")
    if len(re.findall(r'^case ["\']?\$1["\']? in\s*$', source, re.M)) != 1:
        raise ValueError("unsupported ramlog command dispatcher")

    # Validate every transformation before returning any output. A distribution
    # update that changes the structure must be reviewed instead of guessed at.
    for name in ("syncToDisk", "syncFromDisk"):
        pattern = r"^(?:function\s+)?" + name + r"\s*\(\s*\)\s*\{[ \t]*\n"
        matches = list(re.finditer(pattern, source, re.M))
        if len(matches) != 1:
            raise ValueError("expected exactly one standalone {} function".format(name))
        match = matches[0]
        insertion = "\treturn 0 # {}\n".format(MARKER)
        if not source[match.end():].startswith(insertion):
            source = source[:match.end()] + insertion + source[match.end():]

    pattern = r'^LOG_OUTPUT=(?:"tee -a \$LOG2RAM_LOG"|cat # flashprotect: ramlog status stays in memory)[ \t]*$'
    if len(re.findall(pattern, source, re.M)) != 1:
        raise ValueError("unsupported LOG_OUTPUT; expected the upstream tee assignment")
    if len(re.findall(r"^LOG_OUTPUT=", source, re.M)) != 1:
        raise ValueError("multiple LOG_OUTPUT assignments are unsupported")
    source = re.sub(pattern, "LOG_OUTPUT=cat # flashprotect: ramlog status stays in memory", source, flags=re.M)

    pattern = r"^[ \t]+postrotate\)[ \t]*\n"
    matches = list(re.finditer(pattern, source, re.M))
    if len(matches) != 1:
        raise ValueError("expected exactly one standalone postrotate command branch")
    match = matches[0]
    insertion = "\t\texit 0 # {}\n".format(MARKER)
    if not source[match.end():].startswith(insertion):
        source = source[:match.end()] + insertion + source[match.end():]
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("input", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    temporary = None
    try:
        mode = args.input.stat().st_mode & 0o777
        with args.input.open("r", encoding="utf-8", newline="") as handle:
            patched = patch_ramlog(handle.read())
        # Validate first, then atomically replace even for same-path staging.
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="\n", delete=False,
            dir=args.output.parent, prefix=".ramlog-protect-"
        ) as handle:
            temporary = Path(handle.name)
            handle.write(patched)
        os.chmod(temporary, mode)
        os.replace(temporary, args.output)
        temporary = None
    except (OSError, UnicodeError, ValueError) as exc:
        print("ramlog-protect: {}".format(exc), file=sys.stderr)
        return 1
    finally:
        if temporary is not None:
            temporary.unlink()
    return 0


if __name__ == "__main__":
    sys.exit(main())
