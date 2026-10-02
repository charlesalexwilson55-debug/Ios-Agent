"""Queue the user's authorized direct download in Conduit's USB documents container."""
import asyncio
import json
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.services.house_arrest import HouseArrestService

async def main():
    lockdown = await create_using_usbmux()
    service = None
    try:
        service = await HouseArrestService.create(lockdown, "com.charles.conduit.64997U5DUX", documents_only=True)
        payload = json.dumps({"tier": "Edge0 35B"}).encode()
        await service.set_file_contents("/Documents/edge0-download-request.json", payload)
        actual = await service.get_file_contents("/Documents/edge0-download-request.json")
        assert actual == payload
        print("Verified: Edge0 35B download is queued for Conduit's next foreground launch.")
    finally:
        if service is not None:
            await service.close()
        await lockdown.close()

asyncio.run(main())
