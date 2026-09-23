"""Stream a public Hugging Face MLX model straight into Conduit's Documents.

Run on the paired Windows computer with pymobiledevice3, aiohttp, and
huggingface_hub installed. Streaming avoids storing a second 6 GB copy on PC.
"""
import asyncio
import hashlib
import sys
import time

import aiohttp
from huggingface_hub import HfApi, hf_hub_url
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService


REPO = sys.argv[1] if len(sys.argv) > 1 else "mlx-community/Qwen3.5-9B-4bit"
FOLDER = sys.argv[2] if len(sys.argv) > 2 else "Qwen3.5-9B-MLX-4bit"
BUNDLE = sys.argv[3] if len(sys.argv) > 3 else "com.charles.conduit.64997U5DUX"
SKIP = {"README.md", ".gitattributes"}


def log(message):
    print(f"[{time.strftime('%H:%M:%S')}] {message}", flush=True)


async def main():
    files = [item for item in HfApi().model_info(REPO, files_metadata=True).siblings
             if item.rfilename not in SKIP]
    files.sort(key=lambda item: item.size or 0)
    lockdown = await create_using_usbmux()
    afc = await HouseArrestService.create(lockdown, BUNDLE, documents_only=True)
    target = f"/Documents/{FOLDER}"
    try:
        await afc.makedirs(target)
        existing = set(await afc.listdir(target))
        missing = []
        for item in files:
            if item.rfilename in existing:
                stat = await afc.stat(f"{target}/{item.rfilename}")
                if int(stat.get("st_size", -1)) == item.size:
                    continue
            missing.append(item)
        needed = sum(item.size or 0 for item in missing)
        free = int((await afc.get_device_info()).get("FSFreeBytes", 0))
        if free < needed + 500_000_000:
            raise RuntimeError(f"Phone needs {needed / 1e9:.2f} GB plus 0.5 GB free; has {free / 1e9:.2f} GB")
        timeout = aiohttp.ClientTimeout(total=None, sock_read=180)
        async with aiohttp.ClientSession(timeout=timeout) as client:
            for item in files:
                name = item.rfilename
                path = f"{target}/{name}"
                if name in existing:
                    stat = await afc.stat(path)
                    if int(stat.get("st_size", -1)) == item.size:
                        log(f"already present: {name}")
                        continue
                log(f"downloading to phone: {name} ({(item.size or 0) / 1e9:.2f} GB)")
                url = hf_hub_url(REPO, name)
                async with client.get(url, allow_redirects=True) as response:
                    response.raise_for_status()
                    handle = await afc.fopen(path, "w")
                    digest = hashlib.sha256()
                    copied = 0
                    next_report = 250_000_000
                    try:
                        async for chunk in response.content.iter_chunked(2_000_000):
                            await afc.fwrite(handle, chunk)
                            digest.update(chunk)
                            copied += len(chunk)
                            if copied >= next_report:
                                log(f"  {copied / 1e9:.2f} / {(item.size or 0) / 1e9:.2f} GB")
                                next_report += 250_000_000
                    finally:
                        await afc.fclose(handle)
                    if copied != item.size:
                        raise RuntimeError(f"Size mismatch for {name}: {copied} != {item.size}")
                    expected = getattr(getattr(item, "lfs", None), "sha256", None)
                    if expected and digest.hexdigest() != expected:
                        raise RuntimeError(f"SHA-256 mismatch for {name}")
                    stat = await afc.stat(path)
                    if int(stat.get("st_size", -1)) != copied:
                        raise RuntimeError(f"Phone copy size mismatch for {name}")
                    log(f"  verified: {name}, {copied} bytes")
        log("MODEL COPIED AND VERIFIED")
    finally:
        await afc.close()


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except Exception as error:
        log(f"FAILED: {error}")
        sys.exit(1)
