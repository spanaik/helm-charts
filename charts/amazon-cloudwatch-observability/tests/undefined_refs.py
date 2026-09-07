#!/usr/bin/env python3
# Copyright Amazon.com, Inc. or its affiliates. All Rights Reserved.
# SPDX-License-Identifier: Apache-2.0

"""Report collector components a pipeline references but no gate defined.

Reads `helm template` output on stdin, prints "none" or a comma-separated list of
`pipeline:kind:component`. Such a reference stops the collector from starting, and
`helm lint` does not catch it.

Stdlib only, so it runs wherever helm does. Not a general YAML parser: it relies
on otelConfig being machine-serialized with stable 2-space indentation.
"""

import json
import re
import sys

SECTIONS = ("receivers", "processors", "exporters", "extensions")


def extract_otel_config(rendered):
    """Pull the otelConfig double-quoted scalar out and unescape it."""
    for line in rendered.splitlines():
        stripped = line.strip()
        if stripped.startswith("otelConfig: "):
            return json.loads(stripped[len("otelConfig: "):])
    return None


def defined_components(lines):
    """Names declared under each top-level receivers/processors/... section."""
    defined = {section: set() for section in SECTIONS}
    section = None
    for line in lines:
        if not line.strip():
            continue
        top = re.match(r"^(\w+):\s*$", line)
        if top:
            section = top.group(1) if top.group(1) in SECTIONS else None
            continue
        if section:
            child = re.match(r"^ {2}([^\s:]+):", line)
            if child:
                defined[section].add(child.group(1))
    return defined


def pipeline_references(lines):
    """{pipeline_name: {kind: [component, ...]}} under service.pipelines."""
    refs = {}
    in_service = in_pipelines = False
    pipeline = kind = None
    for line in lines:
        if not line.strip():
            continue
        if re.match(r"^\w+:\s*$", line):
            in_service = line.startswith("service:")
            in_pipelines = False
            continue
        if not in_service:
            continue
        if re.match(r"^ {2}\S", line):
            in_pipelines = bool(re.match(r"^ {2}pipelines:\s*$", line))
            pipeline = kind = None
            continue
        if not in_pipelines:
            continue
        name = re.match(r"^ {4}(\S+):\s*$", line)
        if name:
            pipeline = name.group(1)
            refs.setdefault(pipeline, {})
            kind = None
            continue
        section = re.match(r"^ {6}(\w+):\s*$", line)
        if section:
            kind = section.group(1) if section.group(1) in SECTIONS else None
            continue
        item = re.match(r"^ {6}- (\S+)\s*$", line)
        if item and pipeline and kind:
            refs[pipeline].setdefault(kind, []).append(item.group(1))
    return refs


def main():
    config = extract_otel_config(sys.stdin.read())
    if config is None:
        print("none")
        return 0

    lines = config.splitlines()
    defined = defined_components(lines)
    dangling = [
        f"{pipeline}:{kind}:{component}"
        for pipeline, kinds in sorted(pipeline_references(lines).items())
        for kind, components in sorted(kinds.items())
        for component in components
        if component not in defined[kind]
    ]
    print(",".join(dangling) if dangling else "none")
    return 1 if dangling else 0


if __name__ == "__main__":
    sys.exit(main())
