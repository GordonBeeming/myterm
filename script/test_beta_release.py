#!/usr/bin/env python3
"""Exercise beta batching, tag identity and publication recovery without credentials."""

import hashlib
import json
import os
from pathlib import Path
import tempfile
import unittest
import urllib.error
from unittest.mock import MagicMock, patch

import beta_release

SHA = "a" * 40
VERSION = "0.0.123"
TAG = f"v{VERSION}-beta"
DIGEST = hashlib.sha256(b"fixture").hexdigest()
BATCH = dict(sha=SHA, version=VERSION, tag=TAG, build="1007", run_id="1234", sha256=DIGEST)
ASSET = dict(name=f"myterm-{VERSION}-aarch64.dmg", state="uploaded", digest=f"sha256:{DIGEST}")


def release(draft=False, assets=None, batch=None):
    """Keep batch identity stable across draft/upload/publication fixture transitions."""
    return dict(tag_name=TAG, prerelease=True, draft=draft,
                body=f"<!-- myterm-beta: {json.dumps(BATCH if batch is None else batch)} -->",
                assets=[ASSET] if assets is None else assets)


class BetaReleaseTests(unittest.TestCase):
    def test_dispatch_accepts_the_api_no_content_response(self):
        """Workflow dispatch returns HTTP 204 rather than the JSON used by other endpoints."""
        response = MagicMock()
        response.__enter__.return_value.status = 204
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo", "GH_TOKEN": "fixture"}), \
                patch.object(beta_release.urllib.request, "urlopen", return_value=response):
            self.assertIsNone(beta_release.github("actions/workflows/beta.yml/dispatches", {"ref": "main"}))

    def test_source_reserves_its_immutable_tag_before_building(self):
        """Late workflow edits must not require a broader publishing token."""
        with patch.object(beta_release, "git", side_effect=[SHA, "123"]), \
                patch.object(beta_release, "verify_tag", side_effect=[False, True]), \
                patch.object(beta_release, "github", side_effect=[
                    {"object": {"sha": SHA}}, {"commit": {"verification": {"verified": True}}}, {}]) as api:
            self.assertEqual(beta_release.reserve_source(), (SHA, VERSION, TAG))
            self.assertEqual(api.call_args.args, ("git/refs", {"ref": f"refs/tags/{TAG}", "sha": SHA}))

    def test_unsigned_source_never_reserves_a_tag(self):
        """A tag must never make an unverified source look releasable."""
        with patch.object(beta_release, "git", return_value=SHA), \
                patch.object(beta_release, "github", side_effect=[
                    {"object": {"sha": SHA}}, {"commit": {"verification": {"verified": False}}}]) as api:
            with self.assertRaises(RuntimeError):
                beta_release.reserve_source()
            self.assertEqual(api.call_count, 2)

    def test_workflow_change_racing_tag_creation_skips_before_building(self):
        """A permission race must not spend platform builds on an obsolete workflow snapshot."""
        error = urllib.error.HTTPError("https://api.github.com", 403, "workflow scope", {}, None)
        with patch.object(beta_release, "git", side_effect=[SHA, "123"]), \
                patch.object(beta_release, "verify_tag", return_value=False), \
                patch.object(beta_release, "github", side_effect=[
                    {"object": {"sha": SHA}}, {"commit": {"verification": {"verified": True}}},
                    error, {"object": {"sha": "b" * 40}}]):
            self.assertIsNone(beta_release.reserve_source())

    def test_stale_events_dispatch_current_main_without_starting_platforms(self):
        """Out-of-order event delivery must still leave a current workflow queued."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output)}), \
                    patch.object(beta_release, "reserve_source", return_value=None), \
                    patch.object(beta_release, "github") as api:
                beta_release.prepare()
            self.assertEqual(api.call_args.args, ("actions/workflows/beta.yml/dispatches", {"ref": "main"}))
            self.assertEqual(output.read_text(), "publish=false\nresume=false\n")

    def prepare(self, existing=None, verified=True, run_number="7"):
        """Isolate orchestration outputs from network and on-disk Git state."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_NUMBER": run_number, "GITHUB_RUN_ID": "5678"}), \
                    patch.object(beta_release, "reserve_source", side_effect=None if verified else RuntimeError("unsigned"),
                                 return_value=(SHA, VERSION, TAG)), \
                    patch.object(beta_release, "verify_tag"), \
                    patch.object(beta_release, "find_release", return_value=existing):
                beta_release.prepare()
            return dict(line.split("=", 1) for line in output.read_text().splitlines())

    def test_new_source_pins_one_version_and_increases_testflight_sequence(self):
        """Both platforms need the same source and a build number above the retired uploader."""
        self.assertEqual(self.prepare(), dict(sha=SHA, version=VERSION, tag=TAG, publish="true",
                                             build_number="1007", resume="false", artifact_run_id="5678", rebuild_companion="false"))

    def test_existing_snapshot_does_not_upload_another_testflight_build(self):
        """Dispatching an already published snapshot must not create another Apple upload."""
        self.assertEqual(self.prepare(release())["publish"], "false")

    def test_recorded_builds_remain_recoverable_after_new_sequence_is_exhausted(self):
        """An exhausted future sequence must not invalidate previously completed artifacts."""
        self.assertEqual(self.prepare(release(), run_number="9000")["publish"], "false")
        self.assertEqual(self.prepare(release(draft=True), run_number="9000")["build_number"], "1007")
        with self.assertRaises(RuntimeError):
            self.prepare(run_number="9000")

    def test_prepare_rejects_a_mismatched_tag_before_platform_outputs(self):
        """Release target_commitish cannot prove the actual Git tag identity."""
        with patch.object(beta_release, "git", side_effect=[SHA, "123"]), \
                patch.object(beta_release, "github", side_effect=[
                    {"object": {"sha": SHA}}, {"commit": {"verification": {"verified": True}}},
                    {"object": {"type": "commit", "sha": "b" * 40}}]), \
                patch.object(beta_release, "find_release") as lookup:
            with self.assertRaises(RuntimeError):
                beta_release.prepare()
            lookup.assert_not_called()

    def test_explicit_companion_rebuild_pins_published_source_and_new_build_only(self):
        """An Apple resubmission must preserve the immutable macOS release."""
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "output"
            with patch.dict(os.environ, {"GITHUB_OUTPUT": str(output), "GITHUB_RUN_NUMBER": "8",
                                         "GITHUB_RUN_ID": "5678", "GITHUB_EVENT_NAME": "workflow_dispatch",
                                         "REBUILD_COMPANION": "true", "REQUESTED_SOURCE_SHA": SHA}), \
                    patch.object(beta_release, "git", side_effect=["", "123"]) as git, \
                    patch.object(beta_release, "github", return_value={"commit": {"verification": {"verified": True}}}), \
                    patch.object(beta_release, "find_release", return_value=release()), \
                    patch.object(beta_release, "verify_tag"):
                beta_release.prepare()
            values = dict(line.split("=", 1) for line in output.read_text().splitlines())
            self.assertEqual(values["sha"], SHA)
            self.assertEqual(values["build_number"], "1008")
            self.assertEqual(values["rebuild_companion"], "true")
            self.assertEqual(values["publish"], "false")
            self.assertEqual(values["resume"], "false")
            self.assertEqual(git.call_args_list[0].args, ("merge-base", "--is-ancestor", SHA, "HEAD"))

    def test_source_override_requires_explicit_rebuild_dispatch(self):
        """Push events must never silently become arbitrary-source resubmissions."""
        with patch.dict(os.environ, {"REQUESTED_SOURCE_SHA": SHA, "REBUILD_COMPANION": "false"}):
            with self.assertRaises(RuntimeError):
                beta_release.prepare()
        with patch.dict(os.environ, {"REBUILD_COMPANION": "true", "GITHUB_EVENT_NAME": "push"}):
            with self.assertRaises(RuntimeError):
                beta_release.prepare()

    def test_draft_resumes_original_artifact_and_build_without_platform_jobs(self):
        """Publication recovery must retain the already successful Apple build."""
        values = self.prepare(release(draft=True, assets=[]))
        self.assertEqual(values["resume"], "true")
        self.assertEqual(values["publish"], "true")
        self.assertEqual(values["artifact_run_id"], "1234")
        self.assertEqual(values["build_number"], "1007")

    def test_unsigned_source_and_conflicting_metadata_fail_closed(self):
        """Metadata from another source or channel cannot authorize publication."""
        with self.assertRaises(RuntimeError):
            self.prepare(verified=False)
        with self.assertRaises(RuntimeError):
            self.prepare(release(batch=dict(BATCH, sha="b" * 40)))
        other = release()
        other["prerelease"] = False
        with self.assertRaises(RuntimeError):
            self.prepare(other)

    def test_lightweight_and_annotated_tags_resolve_to_the_source(self):
        """Tag objects can nest and must be peeled before comparing commit identity."""
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
        """A draft hidden beyond the first page must not cause a duplicate publication."""
        draft = release(draft=True)
        with patch.object(beta_release, "github", side_effect=[
                [{"tag_name": f"other-{n}"} for n in range(100)], [draft]]) as api:
            self.assertEqual(beta_release.find_release(TAG), draft)
            self.assertEqual(api.call_args.args[0], "releases?per_page=100&page=2")

    def publish(self, responses):
        """Replay release API states while recording every attempted mutation."""
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
        """Users must never receive a published beta before the asset digest is checked."""
        calls, checks = self.publish([None, release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["create", "upload", "edit"])
        self.assertIn("--prerelease", calls[0])
        self.assertIn("--draft", calls[0])
        self.assertIn("--latest=false", calls[-1])
        self.assertIn("--verify-tag", calls[0])
        self.assertNotIn("--target", calls[0])
        self.assertEqual(checks, 3)

    def test_retry_after_asset_upload_does_not_create_or_upload_again(self):
        """A completed upload must remain untouched when only publication needs retrying."""
        calls, _ = self.publish([release(draft=True), release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["edit"])
        self.assertIn("--draft=false", calls[0])

    def test_retry_before_asset_upload_reuses_draft(self):
        """A network failure before upload must not leave the snapshot permanently blocked."""
        calls, _ = self.publish([release(draft=True, assets=[]), release(draft=True)])
        self.assertEqual([call[2] for call in calls], ["upload", "edit"])

    def test_completed_publication_is_idempotent(self):
        """A successful release remains immutable even if the final job response was lost."""
        calls, _ = self.publish([release()])
        self.assertEqual(calls, [])

    def test_empty_failed_upload_marker_can_be_recovered(self):
        """GitHub can retain a zero-byte starter after rejecting an upload."""
        with patch.dict(os.environ, {"GITHUB_REPOSITORY": "owner/repo"}):
            calls, _ = self.publish([release(draft=True, assets=[dict(ASSET, state="starter", size=0, id=42)]),
                                     release(draft=True)])
        self.assertEqual(calls[0], ["gh", "api", "--method", "DELETE", "repos/owner/repo/releases/assets/42"])
        self.assertEqual([call[2] for call in calls[1:]], ["upload", "edit"])

    def test_mismatched_asset_and_build_metadata_cannot_be_published(self):
        """Recovery must not mix signed bytes or Apple build identities from another batch."""
        with self.assertRaises(RuntimeError):
            self.publish([release(draft=True, batch=dict(BATCH, build="1008"))])
        with self.assertRaises(RuntimeError):
            self.publish([release(draft=True, assets=[dict(ASSET, digest="sha256:bad")]),
                          release(draft=True, assets=[dict(ASSET, digest="sha256:bad")])])


if __name__ == "__main__":
    unittest.main()
