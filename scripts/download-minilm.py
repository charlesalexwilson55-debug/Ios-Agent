"""Fetch the pinned, portable Core ML MiniLM package and WordPiece vocabulary."""
import hashlib
from pathlib import Path
import urllib.request

ROOT = Path(__file__).resolve().parents[1] / "App/Resources/SemanticSearch"
REVISION = "c683f20435a63c9884472f5de9f56865e865fd99"
BASE = f"https://huggingface.co/haihengh/all-MiniLM-L6-v2-coreml/resolve/{REVISION}/"
FILES = [
    ("all-minilm-l6-v2.mlpackage/Manifest.json", "MiniLM.mlpackage/Manifest.json", "git", "151b4e148631f31eac39b1a5f7eaa6b1b6b4552b"),
    ("all-minilm-l6-v2.mlpackage/Data/com.apple.CoreML/model.mlmodel", "MiniLM.mlpackage/Data/com.apple.CoreML/model.mlmodel", "sha256", "6201aeebdc5d31966147fc286890a7c4eb9cff31bce925b683dc5a6ac62497c7"),
    ("all-minilm-l6-v2.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "MiniLM.mlpackage/Data/com.apple.CoreML/weights/weight.bin", "sha256", "84cbd97f75e18368c9ba9566bb51614f8f7d56f659c171124bf4447cc2145bde"),
    ("tokenizer/vocab.txt", "minilm-vocab.txt", "git", "fb140275c155a9c7c5a3b3e0e77a9e839594a938"),
]

def digest(data, algorithm):
    if algorithm == "git":
        return hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
    return hashlib.sha256(data).hexdigest()

def main():
    for source, destination, algorithm, expected in FILES:
        path = ROOT / destination
        data = path.read_bytes() if path.exists() else b""
        if digest(data, algorithm) != expected:
            with urllib.request.urlopen(BASE + source, timeout=120) as response:
                data = response.read()
            if digest(data, algorithm) != expected:
                raise RuntimeError(f"Hash mismatch: {source}")
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(data)
        print(f"Verified {destination}: {len(data)} bytes")

if __name__ == "__main__":
    main()
