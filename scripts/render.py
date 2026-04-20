#!/usr/bin/env python3
"""Render Jinja2 templates from config.yaml.

Walks --input (file or directory), renders every *.j2 against config.yaml,
writes the result to --output with the .j2 suffix stripped. Files under any
_macros/ directory are loader-only and never emitted.

Replaces makejinja. Requires python-jinja and python-yaml.
"""
from __future__ import annotations

import argparse
import sys
from pathlib import Path

import yaml
from jinja2 import Environment, FileSystemLoader, StrictUndefined

SUFFIX = ".j2"
MACROS_DIR = "_macros"


def load_data(config_path: Path) -> dict:
    with config_path.open() as f:
        return yaml.safe_load(f) or {}


def iter_templates(root: Path):
    for path in sorted(root.rglob(f"*{SUFFIX}")):
        if MACROS_DIR in path.relative_to(root).parts:
            continue
        yield path


def render_one(env: Environment, template_name: str, data: dict, out_path: Path) -> None:
    rendered = env.get_template(template_name).render(**data)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_text(rendered)


def make_env(loader_root: Path) -> Environment:
    return Environment(
        loader=FileSystemLoader(str(loader_root)),
        undefined=StrictUndefined,
        keep_trailing_newline=True,
        trim_blocks=True,
        lstrip_blocks=True,
    )


def render(input_path: Path, output_path: Path, data: dict) -> int:
    if input_path.is_file():
        if input_path.suffix != SUFFIX:
            print(f"error: {input_path} is not a *.j2 file", file=sys.stderr)
            return 2
        env = make_env(input_path.parent)
        out_file = output_path / input_path.with_suffix("").name
        render_one(env, input_path.name, data, out_file)
        return 0

    if not input_path.is_dir():
        print(f"error: {input_path} does not exist", file=sys.stderr)
        return 2

    env = make_env(input_path)
    for template_path in iter_templates(input_path):
        rel = template_path.relative_to(input_path)
        template_name = rel.as_posix()
        out_file = output_path / rel.with_suffix("")
        render_one(env, template_name, data, out_file)
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input", required=True, type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--data", default=Path("config.yaml"), type=Path)
    args = parser.parse_args()

    data = load_data(args.data)
    return render(args.input, args.output, data)


if __name__ == "__main__":
    sys.exit(main())
