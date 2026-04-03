#!/usr/bin/env python3
"""ccs-review-render.py — Render review JSON to HTML/PDF via Jinja2.

Usage: echo '{"session_id":...}' | python3 ccs-review-render.py
       echo '{"range":...}' | python3 ccs-review-render.py --weekly
       echo '{"session_id":...}' | python3 ccs-review-render.py --pdf
       echo '{"range":...}' | python3 ccs-review-render.py --weekly --pdf

Reads JSON from stdin, outputs HTML to stdout (or PDF bytes with --pdf).
Requires weasyprint for --pdf: pip3 install weasyprint
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

    weekly = "--weekly" in sys.argv
    pdf_mode = "--pdf" in sys.argv
    template_name = "review-weekly.html" if weekly else "review.html"
    template = env.get_template(template_name)

    html = template.render(**data)

    if pdf_mode:
        try:
            from weasyprint import HTML
        except ImportError:
            print("Error: weasyprint not installed. Run: pip3 install weasyprint", file=sys.stderr)
            sys.exit(1)
        pdf_bytes = HTML(string=html).write_pdf()
        sys.stdout.buffer.write(pdf_bytes)
    else:
        print(html)


if __name__ == "__main__":
    main()
