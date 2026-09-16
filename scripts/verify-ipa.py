"""Verify a built Conduit IPA before anyone tries to sideload it.

Modelled on the verifier in sovereign-earth, extended for this app's specific
failure modes. Every check here exists because the alternative is discovering
the problem on the phone, after a re-sign and an install — a slow loop worth
avoiding.
"""
import hashlib
import plistlib
import struct
import sys
import zipfile
from pathlib import Path

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC = 0xCAFEBABE
FAT_CIGAM = 0xBEBAFECA
CPU_TYPE_ARM64 = 0x0100000C
MH_EXECUTE = 2

BUNDLE_ID = "com.charles.conduit"
APP = "Payload/Conduit.app/"

# Every permission the tools actually request. A missing usage string is not a
# warning on iOS: the app is killed the instant it touches that API, which
# presents as "Conduit crashes when I ask it about my calendar".
REQUIRED_USAGE_KEYS = [
    "NSCalendarsFullAccessUsageDescription",
    "NSRemindersFullAccessUsageDescription",
    "NSContactsUsageDescription",
]

# Schemes the tools open. canOpenURL returns false for anything unlisted even
# when the target app is installed, which makes capability checks silently lie.
REQUIRED_SCHEMES = ["sms", "tel", "shortcuts", "maps", "music"]

failures = []


def check(condition, message):
    if not condition:
        failures.append(message)


def read_macho_header(data):
    """Returns (cpu_type, file_type) for a thin or fat Mach-O."""
    (magic,) = struct.unpack("<I", data[:4])
    if magic in (FAT_MAGIC, FAT_CIGAM):
        # Fat header is big-endian; take the first architecture.
        _, nfat = struct.unpack(">II", data[:8])
        cpu_type, _, offset, _, _ = struct.unpack(">iiIII", data[8:28])
        thin = data[offset:offset + 32]
        _, thin_cpu, _, thin_type = struct.unpack("<IiiI", thin[:16])
        return thin_cpu, thin_type
    if magic == MH_MAGIC_64:
        _, cpu_type, _, file_type = struct.unpack("<IiiI", data[:16])
        return cpu_type, file_type
    return None, None


def main():
    if len(sys.argv) < 2:
        print("usage: verify-ipa.py <path-to-ipa>", file=sys.stderr)
        return 2

    path = Path(sys.argv[1])
    if not path.exists():
        print(f"No such file: {path}", file=sys.stderr)
        return 2

    with zipfile.ZipFile(path) as z:
        names = z.namelist()

        check(any(n.startswith(APP) for n in names),
              f"Expected an app bundle at {APP}")

        info = plistlib.loads(z.read(APP + "Info.plist"))

        # --- Binary ---------------------------------------------------------
        executable = info.get("CFBundleExecutable")
        check(executable == "Conduit", f"CFBundleExecutable was {executable!r}")
        binary = z.read(APP + executable)
        cpu_type, file_type = read_macho_header(binary)
        check(cpu_type == CPU_TYPE_ARM64,
              f"Expected an arm64 binary, got cpu_type {cpu_type}")
        check(file_type == MH_EXECUTE,
              f"Expected a Mach-O executable, got file type {file_type}")

        # --- Identity -------------------------------------------------------
        check(info.get("CFBundleIdentifier") == BUNDLE_ID,
              f"CFBundleIdentifier was {info.get('CFBundleIdentifier')!r}")

        minimum = info.get("MinimumOSVersion", "0")
        check(int(str(minimum).split(".")[0]) >= 26,
              f"MinimumOSVersion is {minimum}; Liquid Glass needs 26.0+")

        # --- Permissions ----------------------------------------------------
        for key in REQUIRED_USAGE_KEYS:
            value = info.get(key)
            check(bool(value) and len(value) > 15,
                  f"Missing or too-short usage string: {key}")

        schemes = info.get("LSApplicationQueriesSchemes", [])
        for scheme in REQUIRED_SCHEMES:
            check(scheme in schemes,
                  f"LSApplicationQueriesSchemes is missing {scheme!r}")

        # --- Sideloading shape ----------------------------------------------
        check(not any("embedded.mobileprovision" in n for n in names),
              "Expected an unsigned package, but a provisioning profile is embedded")
        check(not any(n.endswith("_CodeSignature/CodeResources") for n in names),
              "Expected an unsigned package, but a code signature is present")

        # The entitlements travel alongside the payload so the re-signing tool
        # can apply them. Without this the increased memory limit is lost and
        # an 8B model will be terminated on load.
        check("Conduit.entitlements" in names,
              "Conduit.entitlements is missing from the IPA; the installer needs it "
              "to preserve the increased-memory-limit entitlement")

        if "Conduit.entitlements" in names:
            entitlements = plistlib.loads(z.read("Conduit.entitlements"))
            check(entitlements.get("com.apple.developer.kernel.increased-memory-limit") is True,
                  "increased-memory-limit entitlement is not set")

        # --- Icon -----------------------------------------------------------
        check(any(n.startswith(APP + "AppIcon") or "AppIcon" in n for n in names),
              "No app icon found in the bundle")

    if failures:
        print(f"INVALID: {path.name}", file=sys.stderr)
        for failure in failures:
            print(f"  - {failure}", file=sys.stderr)
        return 1

    size = path.stat().st_size
    print(f"VALID unsigned arm64 IPA: {path.name}")
    print(f"Bytes: {size:,} ({size / 1_048_576:.1f} MiB)")
    print(f"SHA256: {hashlib.sha256(path.read_bytes()).hexdigest()}")
    print()
    print("Next: re-sign and install with Sideloadly (Windows) using your Apple ID,")
    print("and make sure the entitlements file is applied so the memory limit is raised.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
