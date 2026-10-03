"""Regenerate the training tool schema from the app's static providers."""
import json
import sys
from pathlib import Path

root = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(root))
from training.make_dataset import swift_tool_descriptors, verify_tool_details_match

tools = []
for tool in swift_tool_descriptors() or []:
    properties = {}
    required = []
    for param in tool["params"]:
        entry = {"type": param["type"], "description": param["description"]}
        if param["allowedValues"]:
            entry["enum"] = param["allowedValues"]
        properties[param["name"]] = entry
        if param["required"]:
            required.append(param["name"])
    tools.append({"type": "function", "function": {"name": tool["name"], "description": tool["description"],
                  "parameters": {"type": "object", "properties": properties, "required": required}}})
if not tools:
    raise SystemExit("No app tools found; schema not written")
verify_tool_details_match(tools)
(root / "training/tools.json").write_text(json.dumps(tools, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
print(f"Synced {len(tools)} static tools")
