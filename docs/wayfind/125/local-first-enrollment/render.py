"""Embed retained native evidence in the standalone discussion page."""
import json
from pathlib import Path

root = Path(__file__).resolve().parent
evidence = json.loads((root / "evidence/macos-arm64.json").read_text())
html = (root / "walkthrough.template.html").read_text().replace(
    "__EVIDENCE__", json.dumps(evidence).replace("<", "\\u003c"))
(root / "walkthrough.html").write_text(html)
artifact = Path.home() / "Developer/artifacts/myterm/local-first-enrollment.html"
artifact.parent.mkdir(parents=True, exist_ok=True)
artifact.write_text(html)
print(artifact)
