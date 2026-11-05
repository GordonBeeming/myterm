#!/usr/bin/env python3
"""Exercise beta batching, tag identity and publication recovery without credentials."""

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import beta_release

SHA = "a" * 40
VERSION = "0.0.123"
TAG = f"v{VERSION}-beta"
DIGEST = hashlib.sha256(b"fixture").hexdigest()
BATCH = dict(sha=SHA, version=VERSION, tag=TAG, build="1007", run_id="1234", sha256=DIGEST)
ASSET = dict(name=f"myterm-{VERSION}-aarch64.dmg", state="uploaded", digest=f"sha256:{DIGEST}")


def release(draft=False, assets=None, batch=None):
    return dict(tag_name=TAG, prerelease=True, draft=draft,
                body=f"<!-- myterm-beta: {json.dumps(BATCH if batch is None else batch)} -->",
                assets=[ASSET] if assets is None else assets)


class BetaReleaseTests(unittest.TestCase):
    def prepare(self, existing=None, verified=True):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_NUMBER": "7", "GITHUB_RUN_ID": "5678"}), \
                    patch.object(beta_release, "git", side_effect=[SHA, "123"]), \
                    patch.object(beta_release, "github", return_value={"commit": {"verification": {"verified": verified}}}), \
                    patch.object(beta_release, "verify_tag"), \
                    patch.object(beta_release, "find_release", return_value=existing):
                beta_release.prepare()
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_new_source_pins_one_version_and_increases_testflight_sequence(self):
        self.assertEqual(self.prepare(), dict(sha=SHA, version=VERSION, tag=TAG, publish="true",
                                             build_number="1007", resume="false", artifact_run_id="5678"))

    def test_existing_snapshot_does_not_upload_another_testflight_build(self):
        self.assertEqual(self.prepare(release())["publish"], "false")

    def test_draft_resumes_original_artifact_and_build_without_platform_jobs(self):
        values = self.prepare(release(draft=True, assets=[]))
        self.assertEqual(values["resume"], "true")
        self.assertEqual(values["publish"], "true")
        self.assertEqual(values["artifact_run_id"], "1234")
        self.assertEqual(values["build_number"], "1007")

    def test_unsigned_source_and_conflicting_metadata_fail_closed(self):
        with self.assertRaises(RuntimeError):
            self.prepare(verified=False)
        with self.assertRaises(RuntimeError):
            self.prepare(release(batch=dict(BATCH, sha="b" * 40)))
        other = release()
        other["prerelease"] = False
        with self.assertRaises(RuntimeError):
            self.prepare(other)

    def test_lightweight_and_annotated_tags_resolve_to_the_source(self):
        with patch.object(beta_release, "github", return_value={"object": {"type": "commit", "sha": SHA}}):
            beta_release.verify_tag(TAG, SHA)
        with patch.object(beta_release, "github", side_effect=[
                {"object": {"type": "tag", "sha": "b" * 40}},
                {"object": {"type": "tag", "sha": "c" * 40}},
                {"object": {"type": "commit", "sha": SHA}}]):
            beta_release.verify_tag(TAG, SHA)
        with patch.object(beta_release, "github", return_value={"object": {"type": "commit", "sha": "b" * 40}}):
            with self.assertRaises(RuntimeError):
                beta_release.verify_tag(TAG, SHA)
        with patch.object(beta_release, "github", return_value=None):
            beta_release.verify_tag(TAG, SHA)
            with self.assertRaises(RuntimeError):
                beta_release.verify_tag(TAG, SHA, required=True)

    def test_release_lookup_includes_drafts_and_paginates(self):
        draft = release(draft=True)
        with patch.object(beta_release, "github", side_effect=[
                [{"tag_name": f"other-{n}"} for n in range(100)], [draft]]) as api:
            self.assertEqual(beta_release.find_release(TAG), draft)
            self.assertEqual(api.call_args.args[0], "releases?per_page=100&page=2")

    def publish(self, responses):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "dist").mkdir()
            (root / "dist" / ASSET["name"]).write_bytes(b"fixture")
            previous = Path.cwd()
            try:
                os.chdir(root)
                with patch.dict(os.environ, {"BETA_SOURCE_SHA": SHA, "BETA_VERSION": VERSION,
                                             "BETA_TAG": TAG, "BETA_BUILD_NUMBER": "1007",
                                             "BETA_ARTIFACT_RUN_ID": "1234", "RUNNER_TEMP": directory}), \
                        patch.object(beta_release.subprocess, "run") as run, \
                        patch.object(beta_release, "verify_tag") as verify, \
                        patch.object(beta_release, "find_release", side_effect=responses):
                    beta_release.publish()
                return [call.args[0] for call in run.call_args_list], verify.call_count
            finally:
                os.chdir(previous)

    def test_publication_is_a_draft_then_verified_asset_then_prerelease(self):
        calls, checks = self.publish([None, release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["create", "upload", "edit"])
        self.assertIn("--prerelease", calls[0])
        self.assertIn("--draft", calls[0])
        self.assertIn("--latest=false", calls[-1])
        self.assertEqual(calls[0][calls[0].index("--target") + 1], SHA)
        self.assertEqual(checks, 3)

    def test_retry_after_asset_upload_does_not_create_or_upload_again(self):
        calls, _ = self.publish([release(draft=True), release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["edit"])
        self.assertIn("--draft=false", calls[0])

    def test_retry_before_asset_upload_reuses_draft(self):
        calls, _ = self.publish([release(draft=True, assets=[]), release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["upload", "edit"])

    def test_completed_publication_is_idempotent(self):
        calls, _ = self.publish([release()])
        self.assertEqual(calls, [])

    def test_empty_failed_upload_marker_can_be_recovered(self):
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo"}):
            calls, _ = self.publish([release(draft=True, assets=[dict(ASSET, state="starter", size=0, id=42)]),
                                     release(draft=True)])
        self.assertEqual(calls[0], ["gh", "api", "--method", "DELETE", "repos/owner/repo/releases/assets/42"])
        self.assertEqual([call[2] for call in calls[1:]], ["upload", "edit"])

    def test_mismatched_asset_and_build_metadata_cannot_be_published(self):
        with self.assertRaises(RuntimeError):
            self.publish([release(draft=True, batch=dict(BATCH, build="1008"))])
        with self.assertRaises(RuntimeError):
            self.publish([release(draft=True, assets=[dict(ASSET, digest="sha256:bad")]),
                          release(draft=True, assets=[dict(ASSET, digest="sha256:bad")])])


if __name__ == "__main__":
    unittest.main()
