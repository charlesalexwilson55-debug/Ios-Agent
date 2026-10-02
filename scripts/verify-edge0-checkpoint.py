"""Validate the pinned conversion layout using small remote headers, not weight downloads."""
import json
import struct
import urllib.request

ROOT = "https://huggingface.co/Edge0/Edge0-35B-A3B-preview/resolve/3fe15cbf2bd5bbcdfd611035e1ac88971ff1cdab/"

def read_range(name, start, count):
    request = urllib.request.Request(ROOT + name, headers={"Range": f"bytes={start}-{start + count - 1}", "Cache-Control": "no-cache"})
    with urllib.request.urlopen(request) as response:
        assert response.status == 206
        assert response.headers["Content-Range"].startswith(f"bytes {start}-{start + count - 1}/")
        value = response.read(count)
        assert len(value) == count
        return value

tensors = {}
for index in range(1, 5):
    filename = f"model-{index:05d}-of-00004.safetensors"
    length = struct.unpack("<Q", read_range(filename, 0, 8))[0]
    assert length < 1_048_576
    header = json.loads(read_range(filename, 8, length))
    for name, entry in header.items():
        if name == "__metadata__":
            continue
        assert name not in tensors
        assert entry["shape"] and all(v > 0 for v in entry["shape"])
        tensors[name] = entry

parts = [(projection, part) for projection in ("gate_proj", "up_proj", "down_proj") for part in ("weight", "scales", "biases")]
for layer in range(40):
    for projection, part in parts:
        name = f"language_model.model.layers.{layer}.mlp.switch_mlp.{projection}.{part}"
        entry = tensors[name]
        expected = 524_288 if part == "weight" else 32_768
        assert entry["shape"][0] == 256
        assert entry["data_offsets"][1] - entry["data_offsets"][0] == expected * 256
        assert entry["dtype"] == ("U32" if part == "weight" else "BF16")

resident = sum(e["data_offsets"][1] - e["data_offsets"][0] for n, e in tensors.items() if ".switch_mlp." not in n)
print(f"Pinned checkpoint verified: {len(tensors)} tensors, 40 layers, 256 experts, all nine expert parts match iOS layout. Resident weights: {resident:,} bytes.")
