import asyncio
from pymobiledevice3.lockdown import create_using_usbmux

async def main():
    lockdown = await create_using_usbmux()
    try:
        info = await lockdown.get_value(domain="com.apple.disk_usage")
        print({k: v for k, v in info.items() if "Available" in k or "Total" in k})
    finally:
        await lockdown.close()

asyncio.run(main())
