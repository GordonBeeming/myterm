"""Regression cases from the hosted simulator catalog: 27.1 is Duo-only."""

import copy
import json
from pathlib import Path
import subprocess
import sys
import unittest

from select_companion_simulator import DUO, select


# Device/runtime identities are a minimal subset of the captured hosted simctl inventory.
PHONE = "com.apple.CoreSimulator.SimDeviceType.iPhone-11"
PAD = "com.apple.CoreSimulator.SimDeviceType.iPad-10th-generation"
CATALOG = {"runtimes": [
    {"version": "27.1", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-1",
     "isAvailable": True, "platform": "iOS", "supportedDeviceTypes": [
         {"name": "iPhone Duo", "productFamily": "iPhone", "identifier": DUO}]},
    {"version": "27.0", "identifier": "com.apple.CoreSimulator.SimRuntime.iOS-27-0",
     "isAvailable": True, "platform": "iOS", "supportedDeviceTypes": [
         {"name": "iPhone 11", "productFamily": "iPhone", "identifier": PHONE},
         {"name": "iPad (10th generation)", "productFamily": "iPad", "identifier": PAD}]},
]}


class SimulatorSelectionTests(unittest.TestCase):
    def test_device_limited_minor_does_not_hide_regular_phone_or_tablet(self):
        for family, device, suffix in [("iPhone", PHONE, "27-0"), ("iPad", PAD, "27-0"),
                                       ("iPhoneDuo", DUO, "27-1")]:
            with self.subTest(family=family):
                runtime, selected = select(CATALOG, family, "27.1")
                self.assertTrue(runtime.endswith(suffix))
                self.assertEqual(selected, device)

    def test_newer_preview_is_used_only_with_a_supporting_sdk(self):
        catalog = copy.deepcopy(CATALOG)
        preview = copy.deepcopy(catalog["runtimes"][1])
        preview.update(version="27.2", identifier="newer-preview")
        catalog["runtimes"].insert(0, preview)
        self.assertNotEqual(select(catalog, "iPhone", "27.1")[0], "newer-preview")
        self.assertEqual(select(catalog, "iPhone", "27.2")[0], "newer-preview")
        self.assertEqual(select(catalog, "iPhoneDuo", "27.2")[1], DUO)

    def test_missing_supported_hardware_fails_explicitly(self):
        catalog = {"runtimes": CATALOG["runtimes"][:1]}
        with self.assertRaisesRegex(ValueError, "iPhone.*SDK 27.1"):
            select(catalog, "iPhone", "27.1")

    def test_unavailable_other_platform_and_malformed_versions_are_ignored(self):
        for platform, available in [("tvOS", True), ("iOS", False)]:
            with self.subTest(platform=platform, available=available):
                catalog = copy.deepcopy(CATALOG)
                excluded = copy.deepcopy(catalog["runtimes"][1])
                excluded.update(platform=platform, isAvailable=available, version="27.1", identifier="excluded")
                catalog["runtimes"].insert(0, excluded)
                self.assertTrue(select(catalog, "iPad", "27.1")[0].endswith("27-0"))
        catalog = copy.deepcopy(CATALOG)
        for platform, available, value in [("tvOS", True, "27.0b1"), ("iOS", False, None), ("iOS", True, "27.0b1")]:
            catalog["runtimes"].insert(0, {"platform": platform, "isAvailable": available,
                                          "version": value, "supportedDeviceTypes": "unusable"})
        self.assertEqual(select(catalog, "iPad", "27.1")[1], PAD)

    def test_other_major_versions_cannot_satisfy_the_selected_sdk(self):
        catalog = {"runtimes": []}
        for value in ["26.5", "28.0"]:
            runtime = copy.deepcopy(CATALOG["runtimes"][1])
            runtime["version"] = value
            catalog["runtimes"].append(runtime)
        with self.assertRaises(ValueError):
            select(catalog, "iPhone", "27.1")

    def test_patch_version_precision_is_preserved(self):
        for value, accepted in [("27.0.1", True), ("27.1.1", False)]:
            with self.subTest(version=value):
                runtime = copy.deepcopy(CATALOG["runtimes"][1])
                runtime["version"] = value
                catalog = {"runtimes": [runtime]}
                if accepted:
                    self.assertEqual(select(catalog, "iPhone", "27.1")[1], PHONE)
                else:
                    with self.assertRaises(ValueError):
                        select(catalog, "iPhone", "27.1")

    def test_versions_are_ordered_numerically(self):
        catalog = copy.deepcopy(CATALOG)
        newer = copy.deepcopy(catalog["runtimes"][1])
        newer.update(version="27.10", identifier="minor-ten")
        catalog["runtimes"].append(newer)
        self.assertEqual(select(catalog, "iPhone", "27.11")[0], "minor-ten")

    def test_shell_interface_emits_only_runtime_and_device_identifiers(self):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name("select_companion_simulator.py")),
                                 "iPhone", "27.1"], input=json.dumps(CATALOG), text=True, capture_output=True, check=True)
        self.assertEqual(result.stdout, f"com.apple.CoreSimulator.SimRuntime.iOS-27-0\t{PHONE}\n")
        self.assertEqual(result.stderr, "")

    def test_shell_failure_contract_has_no_partial_output_or_traceback(self):
        device_error = copy.deepcopy(CATALOG)
        device_error["runtimes"][1]["supportedDeviceTypes"] = ["not an object"]
        for data, sdk in [(json.dumps({"runtimes": []}), "27.1"), (json.dumps(CATALOG), "invalid"),
                          ("", "27.1"), ("bad JSON", "27.1"), ("{}", "27.1"),
                          (json.dumps({"runtimes": ["not an object"]}), "27.1"),
                          (json.dumps(device_error), "27.1")]:
            with self.subTest(data=data, sdk=sdk):
                result = subprocess.run([sys.executable, str(Path(__file__).with_name("select_companion_simulator.py")),
                                         "iPhone", sdk], input=data, text=True, capture_output=True)
                self.assertEqual(result.returncode, 2)
                self.assertEqual(result.stdout, "")
                self.assertIn("error:", result.stderr)
                self.assertNotIn("Traceback", result.stderr)


if __name__ == "__main__":
    unittest.main()
