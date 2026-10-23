#!/usr/bin/python3
"""Launch an unchanged, private Logic copy with a build-bound native ARA bridge."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import plistlib
import shutil
import subprocess
import sys
import time
import uuid

VERSION = "0.1.0-alpha.1"
ENGINE = Path("Contents/Frameworks/MAAudioEngine.framework/Versions/A/MAAudioEngine")
MACORE = Path("Contents/Frameworks/MACore.framework/Versions/A/MACore")
MACORE_HASH = "331ce81830f253f3d47f9a219264a51c92bd1d66f03cafd166f04a8b5d6a745b"
EXECUTABLE = Path("Contents/MacOS/Logic Pro")
SUPPORTED = {
    ("12.4", "6707"): "f1ec685f407cd8a9ec73d3e94cdf3f7929bdcaa2168f221913c950bae76fec24"
}
ROOT = Path(__file__).resolve().parent
LSREGISTER = Path("/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def run(argv, **kwargs):
    return subprocess.run([str(a) for a in argv], check=True, **kwargs)


def inspect_logic(app: Path, verify_signature: bool = True) -> dict:
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise RuntimeError("This release requires a native Apple Silicon Mac.")
    app = app.expanduser().resolve(strict=True)
    with (app / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    version = (info.get("CFBundleShortVersionString"), info.get("CFBundleVersion"))
    expected = SUPPORTED.get(version)
    if info.get("CFBundleIdentifier") != "com.apple.logic10" or not expected:
        raise RuntimeError(f"Unsupported Logic build {version[0]} ({version[1]}). Supported: 12.4 (6707).")
    engine_hash = sha256(app / ENGINE)
    if engine_hash != expected:
        raise RuntimeError("Logic engine differs from the qualified build; refusing to launch.")
    macore_hash = sha256(app / MACORE)
    if macore_hash != MACORE_HASH:
        raise RuntimeError("Logic MACore differs from the qualified build; refusing to launch.")
    if verify_signature:
        run(["/usr/bin/codesign", "--verify", "--strict", app], capture_output=True)
        run(["/usr/bin/codesign", "--verify", '-R=anchor apple generic and identifier "com.apple.logic10"', app], capture_output=True)
    return {"source": str(app), "version": version[0], "build": version[1],
            "engine_sha256": engine_hash, "macore_sha256": macore_hash,
            "executable_sha256": sha256(app / EXECUTABLE)}


def unregister(app: Path):
    # Never set a default handler. Remove only this owned copy's registration.
    subprocess.run([str(LSREGISTER), "-u", str(app)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def prepare_copy(source: Path, destination: Path, receipt: dict):
    if destination.exists():
        raise RuntimeError("Private destination already exists; use a fresh run directory.")
    destination.parent.mkdir(parents=True, exist_ok=True)
    run(["/bin/cp", "-cR", source, destination], capture_output=True)
    copied = inspect_logic(destination)
    for key in ("engine_sha256", "macore_sha256", "executable_sha256"):
        if copied[key] != receipt[key]:
            raise RuntimeError("Private copy failed verification.")
    unregister(destination)


def launch(source: Path, project: Path | None, cache: Path, helper: Path,
           *, extra_helpers=(), extra_env=None, wait=True) -> dict:
    """Internal extra_helpers hook is used only by the separate renderer qualification."""
    source = source.expanduser().resolve(strict=True)
    receipt = inspect_logic(source)
    helper = helper.resolve(strict=True)
    if ":" in str(helper) or any(":" in str(p) for p in extra_helpers):
        raise RuntimeError("Helper paths cannot contain a colon.")
    if project is not None:
        project = project.expanduser().resolve(strict=True)
        if project.suffix != ".logicx":
            raise RuntimeError("Select a .logicx project or omit the project to start Logic.")
    cache = cache.expanduser().resolve()
    cache.mkdir(parents=True, exist_ok=True)
    lock = cache / "active.lock"
    try:
        lock.mkdir()
    except FileExistsError:
        raise RuntimeError(f"A launcher session is active, or needs cleanup. See {lock}. Close that copy before removing a stale lock.")
    run_dir = cache / "runs" / uuid.uuid4().hex
    run_dir.mkdir(parents=True)
    app = run_dir / "Logic Pro.app"
    log_path = run_dir / "bridge.log"
    receipt.update({"launcher_version": VERSION, "run_directory": str(run_dir),
                    "owned_app": str(app), "project": str(project) if project else None,
                    "helper_sha256": sha256(helper), "status": "preparing"})
    manifest = run_dir / "session.json"
    def save():
        manifest.write_text(json.dumps(receipt, indent=2) + "\n")
    save()
    (lock / "owner.json").write_text(json.dumps({"launcher_pid": os.getpid(), "session": str(manifest)}))
    process = None
    external_detach_value = (extra_env or {}).get("LOGIC_ARA_DETACH_REQUEST_FILE")
    external_detach = Path(external_detach_value) if external_detach_value else None
    def detach_requested():
        return (run_dir / "detach.request").exists() or (external_detach is not None and external_detach.exists())
    try:
        prepare_copy(source, app, receipt)
        env = dict(os.environ)
        # Do not inherit another tool's process injection or dyld search overrides.
        for key in list(env):
            if key.startswith("DYLD_"):
                del env[key]
        env.update(extra_env or {})
        env.update({"DYLD_INSERT_LIBRARIES": ":".join(str(p) for p in (helper, *extra_helpers)),
                    "LOGIC_ARA_APP_PATH": str(app), "LOGIC_ARA_LOG_PATH": str(log_path),
                    "LOGIC_ARA_PROJECT_PATH": str(project) if project else "",
                    "LOGIC_ARA_PARENT_PID": str(os.getpid()),
                    "LOGIC_ARA_PREFERENCES_DOMAIN": "org.rysupaudio.logic-ara-launcher"})
        args = [str(app / EXECUTABLE)]
        if project:
            args.append(str(project))
        args += ["-ApplePersistenceIgnoreState", "YES", "-NSQuitAlwaysKeepsWindows", "NO"]
        with (run_dir / "console.log").open("ab") as console:
            process = subprocess.Popen(args, env=env, cwd=run_dir, stdin=subprocess.DEVNULL,
                                       stdout=console, stderr=console, start_new_session=True)
        receipt.update({"pid": process.pid, "status": "starting"})
        save()
        deadline = time.monotonic() + 20
        while time.monotonic() < deadline:
            if detach_requested():
                receipt.update({"status": "detached", "reason": "Ownership released; Logic remains open."})
                save()
                return receipt
            log = log_path.read_text(errors="replace") if log_path.exists() else ""
            if "bridge_ready" in log:
                receipt["status"] = "running"
                save()
                break
            if process.poll() is not None:
                raise RuntimeError(f"Private Logic exited ({process.returncode}); see {run_dir}.")
            if "bridge_refused" in log:
                raise RuntimeError(f"Bridge refused the process; see {log_path}.")
            time.sleep(0.2)
        else:
            raise RuntimeError(f"Bridge startup was not confirmed; see {run_dir}.")
        unregister(app)
        print(f"Private Logic PID {process.pid}. Diagnostics: {run_dir}", flush=True)
        if not wait:
            raise ValueError("Detached launch is unsupported: the launcher must own cleanup.")
        while process.poll() is None:
            if detach_requested():
                receipt.update({"status": "detached", "reason": "Ownership released; Logic remains open."})
                save()
                return receipt
            time.sleep(0.2)
        receipt.update({"status": "exited", "exit_code": process.returncode})
        return receipt
    except BaseException as error:
        receipt.update({"status": "failed", "error": str(error)})
        # A user can open a real project in a formerly owned worker. Never close
        # or terminate Logic based only on its original PID or startup argv.
        if process is not None and process.poll() is None:
            receipt["status"] = "detached"
            receipt["reason"] = "Launcher stopped; live Logic and its private copy were preserved."
        raise
    finally:
        owned_alive = process is not None and process.poll() is None
        cleanup_error = None
        if app.exists() and not owned_alive:
            unregister(app)
            # Exact generated directory only; no broad recursive discovery.
            if app.parent == run_dir and run_dir.parent == cache / "runs" and not app.is_symlink():
                try:
                    shutil.rmtree(app)
                except OSError as error:
                    cleanup_error = str(error)
                    receipt["cleanup_error"] = cleanup_error
        if owned_alive:
            receipt["cleanup_pending"] = "Owned child is still running; its copy and lock are preserved."
        try:
            after = inspect_logic(source)
            receipt["source_unchanged"] = all(after[k] == receipt[k] for k in ("engine_sha256", "macore_sha256", "executable_sha256"))
        except (RuntimeError, OSError, subprocess.SubprocessError) as error:
            receipt["source_unchanged"] = False
            receipt["source_verification_error"] = str(error)
        save()
        if not owned_alive:
            (lock / "owner.json").unlink(missing_ok=True)
            lock.rmdir()
        if not receipt["source_unchanged"]:
            raise RuntimeError(f"Post-run source verification failed; see {manifest}.")
        if cleanup_error:
            raise RuntimeError(f"Private-copy cleanup needs attention; see {manifest}.")


class UserCancelled(Exception):
    pass


def dialog(script: str, *args: str) -> str:
    try:
        return run(["/usr/bin/osascript", "-e", script, *args], capture_output=True, text=True).stdout.strip()
    except subprocess.CalledProcessError as error:
        if "(-128)" in (error.stderr or ""):
            raise UserCancelled() from None
        raise


def gui_arguments() -> list[str] | None:
    action = dialog('choose from list {"Launch Logic", "Open a project", "Check compatibility"} with title "Logic ARA Launcher" with prompt "Experimental native ARA · private Logic copy" default items {"Open a project"}')
    if action == "false":
        return None
    args = []
    source = Path("/Applications/Logic Pro.app")
    if not source.exists():
        picked = dialog('POSIX path of (choose application with prompt "Select your licensed Logic Pro application" as alias)')
        args += ["--logic", picked]
    if action == "Check compatibility":
        args += ["--check"]
    elif action == "Open a project":
        picked = dialog('POSIX path of (choose file with prompt "Select a backed-up .logicx project" of type {"com.apple.logicx.project"})')
        args.append(picked)
    return args


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", nargs="?", type=Path)
    parser.add_argument("--logic", type=Path, default=Path("/Applications/Logic Pro.app"))
    parser.add_argument("--check", action="store_true", help="Verify compatibility without copying or launching Logic")
    parser.add_argument("--gui", action="store_true")
    parser.add_argument("--version", action="version", version=VERSION)
    args = parser.parse_args(argv)
    gui = args.gui
    if args.gui:
        selection = gui_arguments()
        if selection is None:
            return
        args = parser.parse_args(selection)
    if args.check:
        result = inspect_logic(args.logic)
        print(json.dumps(result, indent=2))
        if gui:
            dialog('on run argv\n display alert "Compatible Logic installation" message (item 1 of argv)\nend run',
                   f"Logic {result['version']} ({result['build']}) passed version, engine hashes and Apple signature verification. The installed application was not changed.")
        return
    helper = ROOT / "native/LogicARABridge.dylib"
    if not helper.exists():
        raise RuntimeError("Build the native helper first: ./build.sh")
    launch(args.logic, args.project, Path.home() / "Library/Caches/LogicARALauncher", helper)


if __name__ == "__main__":
    try:
        main()
    except UserCancelled:
        sys.exit(0)
    except (RuntimeError, OSError, subprocess.SubprocessError) as error:
        print(f"Logic ARA Launcher: {error}", file=sys.stderr)
        if "--gui" in sys.argv:
            try:
                dialog('on run argv\n display alert "Logic ARA Launcher" message (item 1 of argv) as critical\nend run', str(error))
            except subprocess.SubprocessError:
                pass
        sys.exit(1)
