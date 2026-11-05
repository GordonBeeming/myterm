#!/usr/bin/env python3
"""Exercise beta source identity, deduplication and stable-channel isolation without credentials."""

import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import beta_release


class BetaReleaseTests(unittest.TestCase):
    def prepare(self, existing=None, verified=True):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_NUMBER": "7"}), \
                    patch.object(beta_release, "git", side_effect=["a" * 40, "123"]), \
                    patch.object(beta_release, "github", side_effect=[
                        {"commit": {"verification": {"verified": verified}}},
                        [] if existing is None else [dict(existing, tag_name="v0.0.123-beta")]]):
                beta_release.prepare()
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_new_source_pins_one_version_and_increases_testflight_sequence(self):
        values = self.prepare()
        self.assertEqual(values, {"sha": "a" * 40, "version": "0.0.123",
                                 "tag": "v0.0.123-beta", "publish": "true", "build_number": "10007"})

    def test_existing_snapshot_does_not_upload_another_testflight_build(self):
        self.assertEqual(self.prepare({"target_commitish": "a" * 40, "prerelease": True, "draft": False, "assets": [{"name": "beta.dmg"}]})["publish"], "false")

    def test_unsigned_source_and_conflicting_tags_fail_closed(self):
        with self.assertRaises(RuntimeError):
            self.prepare(verified=False)
        with self.assertRaises(RuntimeError):
            self.prepare({"target_commitish": "b" * 40, "prerelease": True, "draft": False, "assets": [{"name": "beta.dmg"}]})
        with self.assertRaises(RuntimeError):
            self.prepare({"target_commitish": "a" * 40, "prerelease": False, "draft": False, "assets": [{"name": "beta.dmg"}]})
        with self.assertRaises(RuntimeError):
            self.prepare({"target_commitish": "a" * 40, "prerelease": True, "draft": True, "assets": []})

    def test_release_lookup_includes_drafts_and_paginates(self):
        draft = {"tag_name": "v0.0.123-beta", "draft": True}
        with patch.object(beta_release, "github", side_effect=[
                [{"tag_name": f"other-{n}"} for n in range(100)], [draft]]) as api:
            self.assertEqual(beta_release.find_release("v0.0.123-beta"), draft)
            self.assertEqual(api.call_args.args[0], "releases?per_page=100&page=2")

    def test_publication_is_a_prerelease_at_the_pinned_sha_with_no_overwrite(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            (root / "dist/myterm-0.0.123-aarch64.dmg").write_bytes(b"fixture")
            previous = Path.cwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, {"BETA_SOURCE_SHA": "a" * 40, "BETA_VERSION": "0.0.123",
                                             "BETA_TAG": "v0.0.123-beta", "BETA_BUILD_NUMBER": "10007",
                                             "RUNNER_TEMP": directory}), \
                        patch.object(beta_release.subprocess, "run") as run, \
                        patch.object(beta_release, "find_release", return_value=None):
                    beta_release.publish()
                args = run.call_args_list[0].args[0]
                self.assertIn("--prerelease", args)
                self.assertIn("--draft", args)
                self.assertIn("--draft=false", run.call_args_list[1].args[0])
                self.assertIn("--latest=false", args)
                self.assertEqual(args[args.index("--target") + 1], "a" * 40)
                self.assertNotIn("--clobber", args)
                with patch.dict(os.environ, {"BETA_SOURCE_SHA": "a" * 40, "BETA_VERSION": "0.0.123",
                                             "BETA_TAG": "v0.0.123-beta", "BETA_BUILD_NUMBER": "10007"}), \
                        patch.object(beta_release, "find_release", return_value={"draft": True}), \
                        patch.object(beta_release.subprocess, "run") as forbidden:
                    with self.assertRaises(RuntimeError):
                        beta_release.publish()
                    forbidden.assert_not_called()
            finally:
                os.chdir(previous)


if __name__ == "__main__":
    unittest.main()
