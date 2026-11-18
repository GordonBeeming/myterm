"""Drive native Rust processes over private pipes; assertions do not implement join policy."""
import argparse
import copy
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import select
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parent


class Peer:
    def __init__(self, binary, *args):
        self.process = subprocess.Popen([str(binary), *map(str, args)], stdin=subprocess.PIPE,
                                        stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)

    def call(self, op, **fields):
        self.process.stdin.write(json.dumps(dict(op=op, **fields)) + "\n")
        self.process.stdin.flush()
        if not select.select([self.process.stdout], [], [], 10)[0]:
            raise RuntimeError("native response deadline")
        line = self.process.stdout.readline()
        if not line:
            return {"exit": self.process.wait(timeout=10)}
        return json.loads(line)

    def close(self):
        if self.process.poll() is None:
            self.process.stdin.close()
            self.process.wait(timeout=10)
        stderr = self.process.stderr.read()
        if stderr:
            raise RuntimeError(stderr)


def run(binary, destination):
    checks = []
    observations = {}

    def check(name, condition):
        if not condition:
            raise AssertionError(name)
        checks.append(name)

    def value(response):
        if not response.get("ok"):
            raise AssertionError(response)
        return response["value"]

    def item(identity, title="Work", server="server-local", runtime="shell-a", workspace="workspace-local"):
        return dict(id=identity, workspace=workspace, workspace_title="Work", title=title, server=server, runtime=runtime)

    with tempfile.TemporaryDirectory(prefix="myterm-local-first-") as scratch:
        account = Path(scratch) / "account"
        account.mkdir(mode=0o700)
        authority = Peer(binary, "authority", account)
        local = Peer(binary, "runtime", "server-local")
        remote = Peer(binary, "runtime", "server-remote")
        peers = [local, remote]
        try:
            local_identity = value(local.call("identity"))
            before = value(local.call("echo", marker="BEFOREJOIN"))
            observations["local_before_join"] = before
            check("local PTY works before any approval", before["pid"] == local_identity["pid"])
            check("local PTY started without account configuration", local.process.args == [str(binary), "runtime", "server-local"])

            def state():
                return value(authority.call("status"))["state"]

            def batch(peer, operation, items, mode="first", epoch=1, account_name="account-a"):
                return value(peer.call("batch", account=account_name, epoch=epoch,
                                       operation=operation, mode=mode, items=items))

            def approve(b):
                return value(authority.call("approve", batch=b))

            def unchanged(name, request):
                expected = {
                    "missing approval": "missing signature",
                    "login flag is not an approval signature": "missing signature",
                    "approval reused for another batch": "approval binding",
                    "tampered server signature": "signature",
                    "cross-account batch": "batch context",
                    "wrong account generation": "batch context",
                    "backup fault": "injected backup failure",
                    "actual filesystem backup open failure": "Is a directory",
                    "actual filesystem state open failure": "Is a directory",
                    "operation identity reused with different content": "operation conflict",
                    "existing content identity collision": "identity conflict",
                    "first-join workspace identity collision": "workspace identity conflict",
                    "contradictory workspace names in one batch": "workspace title conflict",
                    "workspace title conflicts with account history": "workspace title conflict",
                    "returning member key substitution": "membership denied",
                    "duplicate IDs within batch": "duplicate identity",
                    "session assigned to another server": "item binding",
                    "failed content validation": "item binding",
                    "existing member cannot repeat first-join mode": "membership mode",
                    "deleted identity reused for another runtime": "tombstone identity conflict",
                    "retry after revocation cannot recover admission": "membership denied",
                    "return after revocation cannot reenroll": "membership denied",
                    "old approval after account deletion flag": "account deleted",
                }[name]
                previous = (account / "state.json").read_bytes()
                result = authority.call(**request)
                check(name + " rejected", result.get("ok") is False)
                check(name + " fails at expected validation", result.get("error", "").startswith(expected))
                observations.setdefault("rejections", {})[name] = result["error"]
                check(name + " preserves durable state", (account / "state.json").read_bytes() == previous)
                check(name + " leaves independent PTY responsive", value(local.call("echo", marker="PRESERVED"))["pid"] == before["pid"])

            ritems = [item("remote-item", server="server-remote", runtime="shell-remote", workspace="workspace-remote")]
            rb = batch(remote, "remote-join", ritems)
            value(authority.call("join", batch=rb, approval=approve(rb)))
            check("existing remote account populated", state()["items"]["remote-item"] == ritems[0])
            litems = [item("local-item"), item("local-tab", title="Browser", runtime="browser-a")]
            first = batch(local, "local-join", litems)
            unchanged("missing approval", dict(op="join", batch=first))
            unchanged("login flag is not an approval signature", dict(op="join", batch=first, approval={"logged_in": True}))
            approval = approve(first)
            altered = batch(local, "altered-batch", [item("injected-item")])
            unchanged("approval reused for another batch", dict(op="join", batch=altered, approval=approval))
            tampered = copy.deepcopy(first)
            tampered["payload"]["items"][0]["title"] = "Tampered"
            unchanged("tampered server signature", dict(op="join", batch=tampered, approval=approval))
            wrong = batch(local, "wrong-account", litems, account_name="account-b")
            unchanged("cross-account batch", dict(op="join", batch=wrong, approval=approval))
            stale = batch(local, "wrong-epoch", litems, epoch=0)
            unchanged("wrong account generation", dict(op="join", batch=stale, approval=approval))
            parent_conflict = batch(local, "workspace-collision", [item("new-content", workspace="workspace-remote")])
            unchanged("first-join workspace identity collision", dict(op="join", batch=parent_conflict, approval=approve(parent_conflict)))
            inconsistent = [item("name-a"), item("name-b")]
            inconsistent[1]["workspace_title"] = "Different"
            inconsistent_batch = batch(local, "workspace-names", inconsistent)
            unchanged("contradictory workspace names in one batch", dict(op="join", batch=inconsistent_batch, approval=approve(inconsistent_batch)))
            unchanged("backup fault", dict(op="join", batch=first, approval=approval, fault="backup"))
            blocked_backup = account / f"backup-{state()['revision']:020d}.pending"
            blocked_backup.mkdir()
            unchanged("actual filesystem backup open failure", dict(op="join", batch=first, approval=approval))
            blocked_backup.rmdir()
            blocked_state = account / "state.pending"
            blocked_state.mkdir()
            unchanged("actual filesystem state open failure", dict(op="join", batch=first, approval=approval))
            blocked_state.rmdir()

            old = (account / "state.json").read_bytes()
            crash = authority.call("join", batch=first, approval=approval, fault="before_commit")
            check("authority exits before commit", crash == {"exit": 71})
            authority.close()
            authority = Peer(binary, "authority", account)
            check("precommit interruption preserves original bytes", (account / "state.json").read_bytes() == old)
            check("precommit interruption preserves shell", value(local.call("echo", marker="PRECOMMIT"))["pid"] == before["pid"])
            crash = authority.call("join", batch=first, approval=approval, fault="after_commit")
            check("authority exits after durable commit before acknowledgment", crash == {"exit": 72})
            authority.close()
            authority = Peer(binary, "authority", account)
            committed = state()
            check("membership survives lost acknowledgment", not committed["members"]["server-local"]["removed"])
            check("all local content and remote content committed together", committed["items"] == {i["id"]: i for i in ritems + litems})
            check("same-name workspaces remain separate", committed["items"]["remote-item"]["workspace_title"] == committed["items"]["local-item"]["workspace_title"] and committed["items"]["remote-item"]["workspace"] != committed["items"]["local-item"]["workspace"])
            retry = value(authority.call("join", batch=first, approval=approval))
            observations["lost_ack_retry_receipt"] = retry
            observations["committed_content"] = committed["items"]
            check("identical retry recovers original receipt", retry["revision"] == committed["revision"])
            check("identical retry creates no duplicate or new revision", state() == committed)
            check("join retains exact original server and runtime identities", state()["items"]["local-item"] == litems[0])
            check("join and authority restart retain original shell", value(local.call("echo", marker="AFTERJOIN"))["pid"] == before["pid"])
            check("remote shell survives another server joining", value(remote.call("echo", marker="REMOTEALIVE"))["pid"] == value(remote.call("identity"))["pid"])

            uncertain = batch(local, "uncertain-commit", [item("uncertain-item")], mode="return")
            crash = authority.call("join", batch=uncertain, fault="after_rename_sync")
            check("uncertain directory commit stops writer", crash == {"exit": 73})
            authority.close()
            authority = Peer(binary, "authority", account)
            check("restart reloads renamed snapshot after uncertain commit", "uncertain-item" in state()["items"])
            receipt = value(authority.call("join", batch=uncertain))
            check("uncertain commit retry recovers receipt", receipt["revision"] == state()["revision"])
            later = batch(local, "after-uncertain", [item("later-item")], mode="return")
            value(authority.call("join", batch=later))
            check("later write preserves earlier uncertain operation", "uncertain-item" in state()["items"])
            remote_same_operation = batch(remote, "after-uncertain", ritems, mode="return")
            check("operation IDs are scoped to server identity", authority.call("join", batch=remote_same_operation).get("ok") is True)
            impostor = Peer(binary, "runtime", "server-local")
            peers.append(impostor)
            impostor_batch = batch(impostor, "key-substitution", litems, mode="return")
            unchanged("returning member key substitution", dict(op="join", batch=impostor_batch))

            reused = batch(local, "local-join", [item("extra")], mode="return")
            unchanged("operation identity reused with different content", dict(op="join", batch=reused))
            conflicting = batch(local, "id-conflict", [item("remote-item")], mode="return")
            unchanged("existing content identity collision", dict(op="join", batch=conflicting))
            duplicate = batch(local, "duplicate-id", [item("twice"), item("twice")], mode="return")
            unchanged("duplicate IDs within batch", dict(op="join", batch=duplicate))
            reassigned = batch(local, "wrong-owner", [item("wrong-owner", server="server-remote")], mode="return")
            unchanged("session assigned to another server", dict(op="join", batch=reassigned))
            invalid = batch(local, "invalid-content", [item("")], mode="return")
            unchanged("failed content validation", dict(op="join", batch=invalid))
            renamed = [item("new-in-renamed-workspace")]
            renamed[0]["workspace_title"] = "Changed offline"
            renamed_batch = batch(local, "rename-conflict", renamed, mode="return")
            unchanged("workspace title conflicts with account history", dict(op="join", batch=renamed_batch))
            repeated = batch(local, "fresh-first", litems)
            unchanged("existing member cannot repeat first-join mode", dict(op="join", batch=repeated, approval=approve(repeated)))

            value(authority.call("delete_item", id="local-item"))
            returning = batch(local, "return-with-history", litems + [item("new-offline-item")], mode="return")
            result = value(authority.call("join", batch=returning))
            check("returning stale item respects explicit deletion", result["skipped_deleted"] == ["local-item"] and "local-item" not in state()["items"])
            check("returning member adds genuinely new offline work", "new-offline-item" in state()["items"])
            check("snapshot absence preserves remote and local work", "remote-item" in state()["items"] and "local-tab" in state()["items"])
            check("tombstone does not terminate any process", value(local.call("echo", marker="TOMBSTONE"))["pid"] == before["pid"])
            incarnation = batch(local, "wrong-incarnation", [item("local-item", runtime="shell-other")], mode="return")
            unchanged("deleted identity reused for another runtime", dict(op="join", batch=incarnation))
            for n in range(7):
                b = batch(local, f"retention-{n}", [item(f"retention-{n}")], mode="return")
                value(authority.call("join", batch=b))
            backups = sorted(account.glob("backup-*.json"))
            check("five original-state backups retained after successful commits", len(backups) == 5)
            check("backups are consecutive original snapshots", [json.loads(p.read_bytes())["revision"] for p in backups] == list(range(state()["revision"] - 5, state()["revision"])))
            check("snapshot keys and backups have private permissions", all((p.stat().st_mode & 0o777) == 0o600 for p in [account / "key", account / "state.json", *backups]))
            contender = Peer(binary, "authority", account)
            check("second account writer refused by OS file lock", contender.process.wait(timeout=10) == 1 and "locked" in contender.process.stderr.read())

            value(authority.call("remove", server="server-local"))
            unchanged("retry after revocation cannot recover admission", dict(op="join", batch=first, approval=approval))
            unchanged("return after revocation cannot reenroll", dict(op="join", batch=batch(local, "revoked-return", litems, mode="return")))
            denied_approval = authority.call("approve", batch=first)
            check("removed member cannot obtain fresh approval", denied_approval == {"ok": False, "error": "removed identity"})
            value(authority.call("delete_account"))
            unchanged("old approval after account deletion flag", dict(op="join", batch=first, approval=approval))
            deleted_approval = authority.call("approve", batch=rb)
            check("account deletion prevents new approval", deleted_approval == {"ok": False, "error": "account deleted"})
            final = value(local.call("echo", marker="FINALALIVE"))
            observations["local_after_all_checks"] = final
            check("all rejection cases leave original local shell alive", final["pid"] == before["pid"])
            shell_pids = [value(peer.call("identity"))["pid"] for peer in peers]
        finally:
            cleanup_errors = []
            for peer in [authority, *peers]:
                try:
                    peer.close()
                except Exception as error:
                    cleanup_errors.append(error)
            if cleanup_errors:
                raise ExceptionGroup("experiment cleanup failed", cleanup_errors)
        for index, peer in enumerate(peers):
            check(f"runtime {index + 1} closes cleanly including the unused PTY", peer.process.returncode == 0)
        for index, pid in enumerate(shell_pids):
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                check(f"disposable shell {index + 1} has been reaped", True)
            else:
                raise AssertionError(f"disposable shell {index + 1} still exists")
    result = dict(scope="native bounded prototype, not MyTerm integration", passed=len(checks), checks=checks,
                  completed_at=datetime.now(timezone.utc).isoformat(), observations=observations,
                  toolchains={command: subprocess.check_output([command, "--version"], text=True).strip()
                              for command in ["rustc", "cargo", "python3"]},
                  platform=platform.platform(), machine=platform.machine(),
                  source_sha256={str(p.relative_to(ROOT)): hashlib.sha256(p.read_bytes()).hexdigest()
                                 for p in [ROOT / "src/main.rs", ROOT / "probe.py", ROOT / "Cargo.toml", ROOT / "Cargo.lock"]})
    destination.mkdir(parents=True, exist_ok=True)
    (destination / "macos-arm64.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(dict(passed=len(checks), evidence=str(destination / "macos-arm64.json"))))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--build", type=Path, default=Path("/private/tmp/myterm-local-first-build"))
    args = parser.parse_args()
    subprocess.run(["cargo", "build", "--offline", "--manifest-path", str(ROOT / "Cargo.toml"),
                    "--target-dir", str(args.build)], check=True)
    run(args.build / "debug/local-first-prototype", args.output)
