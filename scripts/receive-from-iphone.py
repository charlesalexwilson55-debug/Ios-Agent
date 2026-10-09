"""Receive Conduit exports over a trusted USB connection. Never overwrites PC files."""
import argparse
import asyncio
import hashlib
import json
from pathlib import Path
import re
import time
import uuid


def safe_name(name):
    if (not isinstance(name, str) or not name or len(name) > 200
            or re.search(r'[\\/:<>"|?*\x00-\x1f]', name)
            or name in (".", "..") or name.endswith((".", " "))
            or name.split('.')[0].upper() in {"CON", "PRN", "AUX", "NUL", *[f"COM{i}" for i in range(1, 10)], *[f"LPT{i}" for i in range(1, 10)]}):
        raise ValueError("Invalid transfer filename")
    return name


def save_payload(folder, name, data, expected_hash):
    name = safe_name(name)
    if hashlib.sha256(data).hexdigest() != expected_hash:
        raise ValueError("Transfer checksum mismatch")
    folder.mkdir(parents=True, exist_ok=True)
    target = folder / name
    counter = 1
    while target.exists():
        target = folder / f"{Path(name).stem} ({counter}){Path(name).suffix}"
        counter += 1
    with target.open('xb') as output:
        output.write(data)
    return target


async def receive(args):
    from pymobiledevice3.lockdown import create_using_usbmux
    from pymobiledevice3.services.house_arrest import HouseArrestService
    async with await create_using_usbmux(serial=args.udid) as lockdown:
        async with await HouseArrestService.create(lockdown, args.bundle, documents_only=True) as afc:
            root = '/Documents/PC Outbox'
            try: await afc.makedirs(root)
            except Exception: pass  # The app may already have created it.
            print('USB receiver connected. Use Send to PC inside Conduit.', flush=True)
            while True:
                await afc.set_file_contents(root + '/receiver.json', json.dumps({'time': time.time()}).encode())
                for name in await afc.listdir(root):
                    if not name.endswith('.request.json'): continue
                    try:
                        identifier = name.removesuffix('.request.json')
                        uuid.UUID(identifier)
                        request = json.loads(await afc.get_file_contents(root + '/' + name))
                        size = request['bytes']
                        if not isinstance(size, int) or not 0 <= size <= 100_000_000:
                            raise ValueError('Transfer too large')
                        data = await afc.get_file_contents(root + '/' + identifier + '.payload')
                        if len(data) != size: raise ValueError('Incomplete transfer')
                        target = save_payload(args.output, request['name'], data, request['sha256'])
                        ack = {'ok': True, 'name': target.name}
                        print('Received:', target, flush=True)
                        # The acknowledgement is written only after a verified PC write.
                        await afc.set_file_contents(root + '/' + identifier + '.ack.json', json.dumps(ack).encode())
                        await afc.rm(root + '/' + name)
                        await afc.rm(root + '/' + identifier + '.payload')
                    except Exception as error:
                        print('Transfer failed:', str(error), flush=True)
                if args.once: break
                await asyncio.sleep(2)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bundle', default='com.charles.conduit.64997U5DUX')
    parser.add_argument('--udid', default=None)
    parser.add_argument('--output', type=Path, default=Path.home() / 'Downloads' / 'Conduit Exports')
    parser.add_argument('--once', action='store_true')
    asyncio.run(receive(parser.parse_args()))
