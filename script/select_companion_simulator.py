"""Select a device-supported runtime that the chosen Xcode SDK can run."""

import argparse
import json
import sys

DUO = "com.apple.CoreSimulator.SimDeviceType.iPhone-Duo"


def version(value):
    """Ignore malformed runtime metadata rather than sorting it as a valid version."""
    if not isinstance(value, str):
        return None
    parts = value.split(".")
    if not 1 <= len(parts) <= 3 or not all(p.isascii() and p.isdecimal() for p in parts):
        return None
    return tuple((list(map(int, parts)) + [0, 0, 0])[:3])


def select(inventory, family, sdk_version):
    """Choose hardware and runtime together: a minor OS release may support one device only."""
    sdk = version(sdk_version)
    if sdk is None:
        raise ValueError(f"Invalid simulator SDK version: {sdk_version}")
    if not isinstance(inventory, dict) or not isinstance(inventory.get("runtimes"), list):
        raise ValueError("simctl inventory has no runtimes list")
    product = {"iPhone": "iPhone", "iPad": "iPad", "iPhoneDuo": "iPhone"}[family]
    runtimes = []
    for runtime in inventory["runtimes"]:
        if not isinstance(runtime, dict):
            raise ValueError("simctl runtime entry must be an object")
        if not runtime.get("isAvailable") or runtime.get("platform") != "iOS":
            continue
        candidate = version(runtime.get("version"))
        if candidate is not None and candidate[0] == sdk[0] and candidate <= sdk:
            runtimes.append((candidate, runtime))
    for _, runtime in sorted(runtimes, key=lambda pair: pair[0], reverse=True):
        if not isinstance(runtime.get("supportedDeviceTypes", []), list):
            raise ValueError("simctl runtime device types must be a list")
        if any(not isinstance(device, dict) for device in runtime.get("supportedDeviceTypes", [])):
            raise ValueError("simctl device type entry must be an object")
        devices = [device for device in runtime.get("supportedDeviceTypes", [])
                   if device.get("productFamily") == product and device.get("identifier")]
        if family == "iPhone":
            devices = [device for device in devices if device["identifier"] != DUO]
        elif family == "iPhoneDuo":
            devices = [device for device in devices if device["identifier"] == DUO]
        if devices:
            chosen = min(devices, key=lambda device: device["name"])
            return runtime["identifier"], chosen["identifier"]
    raise ValueError(f"No available iOS {sdk[0]}.x {family} runtime/device type compatible with selected SDK {sdk_version}.")


def main():
    """Keep stdout as the two tab-separated identifiers consumed by test_companion.sh."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("family", choices=["iPhone", "iPad", "iPhoneDuo"])
    parser.add_argument("sdk_version")
    args = parser.parse_args()
    try:
        print("\t".join(select(json.load(sys.stdin), args.family, args.sdk_version)))
    except (ValueError, KeyError, TypeError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
