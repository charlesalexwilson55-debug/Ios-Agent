"""Download the official pinned Ornith MLX export, checking each source hash."""
import hashlib
import json
from pathlib import Path
import urllib.request
import urllib.error
import time

MODEL = "ornith-ai/Ornith-1.5-9B-MLX-4bit"
REVISION = "a48173b246ac705be75c05bedf1a0666db522d53"
ROOT = Path(__file__).resolve().parents[1] / "models/Ornith-1.5-9B-MLX-4bit"

def main():
    ROOT.mkdir(parents=True, exist_ok=True)
    with urllib.request.urlopen(f"https://huggingface.co/api/models/{MODEL}/revision/{REVISION}?blobs=true") as response:
        manifest = json.load(response)
    for file in manifest["siblings"]:
        name = file["rfilename"]
        if not name.endswith((".json", ".safetensors", ".jinja")) or "/" in name:
            continue
        path = ROOT / name
        if not path.exists() or path.stat().st_size != file["size"]:
            temporary = path.with_suffix(path.suffix + ".part")
            if path.exists() and not temporary.exists():
                path.replace(temporary)
            failures = 0
            while failures < 12:
                offset = temporary.stat().st_size if temporary.exists() else 0
                if offset == file["size"]:
                    break
                end = min(offset + 64 * 1024 * 1024, file["size"]) - 1
                request = urllib.request.Request(f"https://huggingface.co/{MODEL}/resolve/{REVISION}/{name}?download=true&offset={offset}&end={end}",
                    headers={"Range": f"bytes={offset}-{end}"})
                try:
                    with urllib.request.urlopen(request, timeout=120) as response:
                        resumed = response.status == 206
                        if resumed and response.headers.get("Content-Range", "") != f"bytes {offset}-{end}/{file['size']}":
                            raise RuntimeError("Unexpected download range")
                        if offset and not resumed:
                            raise OSError("Server ignored resume range")
                        with temporary.open("ab" if resumed else "wb") as output:
                            total = offset if resumed else 0
                            while chunk := response.read(8 * 1024 * 1024):
                                output.write(chunk)
                                total += len(chunk)
                                if total > file["size"]:
                                    raise RuntimeError("Unexpected download size")
                                if total // (256 * 1024 * 1024) != (total - len(chunk)) // (256 * 1024 * 1024):
                                    print(f"{name}: {total / 1e9:.2f} GB", flush=True)
                        if total != (end + 1 if resumed else file["size"]):
                            raise OSError("Response ended before requested range completed")
                        failures = 0
                except (OSError, TimeoutError) as error:
                    failures += 1
                    detail = f"HTTP {error.code}" if isinstance(error, urllib.error.HTTPError) else str(error).split("https://")[0][:160]
                    print(f"Retrying interrupted {name}: {type(error).__name__}: {detail}", flush=True)
                    time.sleep(2)
            if not temporary.exists() or temporary.stat().st_size != file["size"]:
                raise RuntimeError(f"Incomplete download: {name}")
            temporary.replace(path)
        hasher = hashlib.sha256() if file.get("lfs") else hashlib.sha1()
        if not file.get("lfs"):
            hasher.update(f"blob {path.stat().st_size}\0".encode())
        with path.open("rb") as source:
            while chunk := source.read(8 * 1024 * 1024):
                hasher.update(chunk)
        expected = file.get("lfs", {}).get("sha256", file["blobId"])
        if hasher.hexdigest() != expected:
            raise RuntimeError(f"Hash mismatch: {name}")
        print(f"Verified {name}: {path.stat().st_size} bytes", flush=True)
    (ROOT / "verified-download.json").write_text(json.dumps({"model": MODEL, "revision": REVISION}))
    print(f"Ready for phone file sharing: {ROOT}", flush=True)

if __name__ == "__main__":
    main()
