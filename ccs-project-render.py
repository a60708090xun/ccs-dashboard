#!/usr/bin/env python3
"""ccs-project-render.py — Render project report JSON to HTML via Jinja2.

Usage: echo '<project-json>' | python3 ccs-project-render.py

Reads JSON from stdin, outputs HTML to stdout.
"""
import sys
import json
from pathlib import Path

try:
    from jinja2 import Environment, FileSystemLoader
except ImportError:
    print("Error: jinja2 not installed. Run: pip3 install jinja2", file=sys.stderr)
    sys.exit(1)


def main():
    script_dir = Path(__file__).parent
    template_dir = script_dir / "templates"

    env = Environment(
        loader=FileSystemLoader(str(template_dir)),
        autoescape=True,
    )

    data = json.load(sys.stdin)
    template = env.get_template("project.html")
    html = template.render(**data)

    sys.stdout.write(html)


if __name__ == "__main__":
    main()
