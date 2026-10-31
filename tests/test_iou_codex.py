"""Regression checks using simulated apt, downloads and Codex; no system changes."""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "iou-codex.sh"
HARNESS = r'''
source "$SCRIPT_UNDER_TEST"
LOCK_DIR="$CASE_DIR/lock"
LOG_FILE="$CASE_DIR/install.log"
export CODEX_HOME="$CASE_DIR/codex-home"
pkill() { printf 'pkill %s\n' "$*" >>"$CASE_DIR/events"; }
pgrep() { return 1; }
print_environment() { :; }
uname() { printf 'Linux\n'; }
have() {
  case "$1" in
    node|npm) [[ "${NO_NPM:-0}" != 1 ]] ;;
    bwrap) [[ "${MISSING_PACKAGES:-}" != *bubblewrap* || -f "$CASE_DIR/apt-installed" ]] ;;
    apt-get|dpkg-query|codex) return 0 ;;
    *) command -v "$1" >/dev/null 2>&1 ;;
  esac
}
dpkg-query() {
  if [[ " ${MISSING_PACKAGES:-} " == *" ${@: -1} "* ]]; then
    return 1
  fi
  printf 'install ok installed'
}
apt-get() {
  printf 'apt %s\n' "$*" >>"$CASE_DIR/events"
  if [[ "${APT_FAIL:-0}" == 1 ]]; then return 42; fi
  if [[ "$1" == install ]]; then touch "$CASE_DIR/apt-installed"; fi
}
bwrap() { printf 'bwrap\n' >>"$CASE_DIR/events"; }
codex() { "$CASE_DIR/bin/codex" "$@"; }
current_codex_version() { printf '0.160.0\n'; }
download_to() {
  printf 'download %s\n' "$1" >>"$CASE_DIR/events"
  cp "$CASE_DIR/installer.sh" "$2"
  if [[ "${DOWNLOAD_FAIL:-0}" == 1 ]]; then return 22; fi
}
main --install-dir "$CASE_DIR/bin" "$@"
'''
INSTALLER = r'''#!/bin/sh
set -eu
printf 'installer %s interactive=%s\n' "$*" "$CODEX_NON_INTERACTIVE" >>"$CASE_DIR/events"
if [ "${INSTALLER_FAIL:-0}" = 1 ]; then exit 43; fi
mkdir -p "$CODEX_INSTALL_DIR"
cp "$CASE_DIR/fake-codex" "$CODEX_INSTALL_DIR/codex"
chmod +x "$CODEX_INSTALL_DIR/codex"
'''
CODEX = r'''#!/bin/sh
if [ "$1" = --version ]; then
  printf 'codex-cli %s\n' "${FAKE_VERSION:-0.160.0}"
  exit 0
fi
if [ "$*" = 'app-server daemon start --help' ]; then
  exit "${NO_DAEMON:-0}"
fi
if [ "$*" = 'features list' ]; then
  if [ "${NO_FEATURE:-0}" != 1 ]; then
    printf 'daemon_auto_start                        stable             %s\n' "${FEATURE_STATE:-true}"
  fi
  printf 'shell_tool                               stable             true\n'
  exit 0
fi
if [ "$*" = 'features disable daemon_auto_start' ]; then
  printf 'features disable daemon_auto_start\n' >>"$CASE_DIR/events"
  exit 0
fi
if [ "$*" = 'app-server daemon start' ]; then
  printf 'daemon start\n' >>"$CASE_DIR/events"
  exit "${DAEMON_FAIL:-0}"
fi
exit 2
'''


class InstallerTests(unittest.TestCase):
    def run_case(self, *args, installed=False, fake_rootfs=False, **settings):
        with tempfile.TemporaryDirectory(prefix="codex-install-test-") as directory:
            root = Path(directory)
            (root / "events").touch()
            (root / "installer.sh").write_text(INSTALLER)
            (root / "fake-codex").write_text(CODEX)
            if installed:
                (root / "bin").mkdir()
                executable = root / "bin" / "codex"
                executable.write_text(CODEX)
                executable.chmod(0o755)
            env = dict(os.environ, SCRIPT_UNDER_TEST=str(SCRIPT), CASE_DIR=directory,
                       IOU_CODEX_PROOT="0")
            # Aísla las pruebas aunque se ejecuten dentro de un PRoot real.
            env.pop("container", None)
            env.pop("PROOT_L2S_DIR", None)
            env.update({key: str(value) for key, value in settings.items()})
            broken_sockets = []
            if fake_rootfs:
                rootfs = root / "rootfs"
                env["PROOT_L2S_DIR"] = str(rootfs / ".l2s")
                for name in ("app-server-control/app-server-control.sock",
                             "app-server-daemon/daemon-updater.sock"):
                    link = Path(str(rootfs) + str(root / "codex-home" / name))
                    link.parent.mkdir(parents=True)
                    link.symlink_to("/tmp/codex-daemon-0/missing-socket")
                    broken_sockets.append(link)
            result = subprocess.run(
                ["bash", "-c", HARNESS, "test", *args], env=env,
                capture_output=True, text=True, timeout=15,
            )
            events = (root / "events").read_text().splitlines()
            self.assertFalse((root / "lock").exists(), result.stderr)
            if fake_rootfs:
                events += [f"socket {link.name} present={link.is_symlink()}"
                           for link in broken_sockets]
            return result, events

    def test_first_install_prepares_system_before_official_installer(self):
        result, events = self.run_case(MISSING_PACKAGES="bubblewrap curl ca-certificates")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(events[:2], [
            "apt update", "apt install -y --no-install-recommends ca-certificates curl bubblewrap",
        ])
        self.assertEqual(events[-2:], ["installer --release latest interactive=1", "daemon start"])

    def test_installed_dependencies_do_not_need_apt_or_npm(self):
        result, events = self.run_case(NO_NPM=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(event.startswith("apt ") for event in events))

    def test_same_version_still_repairs_official_installation(self):
        result, events = self.run_case("--version", "rust-v0.160.0", installed=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("installer --release 0.160.0 interactive=1", events)
        self.assertIn("daemon start", events)

    def test_same_version_binary_still_installs_missing_bubblewrap(self):
        result, events = self.run_case(
            "--method", "binary", "--version", "0.160.0",
            installed=True, MISSING_PACKAGES="bubblewrap",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("apt install -y --no-install-recommends bubblewrap", events)
        self.assertEqual(events[-1], "daemon start")
        self.assertFalse(any(event.startswith("download ") for event in events))

    def test_apt_failure_stops_before_downloading(self):
        result, events = self.run_case(MISSING_PACKAGES="bubblewrap", APT_FAIL=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(events, ["apt update"])

    def test_partial_download_is_never_executed(self):
        result, events = self.run_case(DOWNLOAD_FAIL=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(event.startswith("installer ") for event in events))

    def test_failed_installer_does_not_report_success(self):
        result, events = self.run_case(INSTALLER_FAIL=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("daemon start", events)
        self.assertNotIn("Resultado final", result.stderr)

    def test_wrong_version_is_rejected(self):
        result, events = self.run_case("--version", "0.160.0", FAKE_VERSION="0.159.0")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("daemon start", events)
        self.assertIn("Verificación fallida", result.stderr)

    def test_daemon_failure_does_not_report_success(self):
        result, events = self.run_case(DAEMON_FAIL=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemon start", events)
        self.assertIn("servidor no arrancó", result.stderr)
        self.assertNotIn("Resultado final", result.stderr)

    def test_older_release_without_daemon(self):
        result, events = self.run_case(NO_DAEMON=2)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("daemon start", events)

    def test_proot_daemon_failure_falls_back_to_embedded_server(self):
        result, events = self.run_case(IOU_CODEX_PROOT=1, DAEMON_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("daemon start", events)
        self.assertIn("features disable daemon_auto_start", events)
        self.assertTrue(any(event.startswith("pkill -f -- ") for event in events))
        self.assertIn("servidor integrado", result.stderr)
        self.assertIn("Resultado final", result.stderr)

    def test_proot_working_daemon_keeps_configuration(self):
        result, events = self.run_case(IOU_CODEX_PROOT=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("daemon start", events)
        self.assertNotIn("features disable daemon_auto_start", events)
        self.assertFalse(any(event.startswith("pkill ") for event in events))

    def test_proot_with_daemon_already_disabled_skips_start(self):
        result, events = self.run_case(IOU_CODEX_PROOT=1, FEATURE_STATE="false", DAEMON_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("daemon start", events)
        self.assertNotIn("features disable daemon_auto_start", events)

    def test_proot_without_feature_flag_reports_no_daemon_hint(self):
        result, events = self.run_case(IOU_CODEX_PROOT=1, NO_FEATURE=1, DAEMON_FAIL=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("daemon start", events)
        self.assertIn("codex --no-daemon", result.stderr)
        self.assertNotIn("Resultado final", result.stderr)

    def test_proot_detected_from_proot_distro_environment(self):
        result, events = self.run_case(IOU_CODEX_PROOT="auto", container="proot-distro",
                                       DAEMON_FAIL=1)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("features disable daemon_auto_start", events)

    def test_proot_removes_broken_socket_links_through_host_rootfs(self):
        result, events = self.run_case(IOU_CODEX_PROOT=1, DAEMON_FAIL=1, fake_rootfs=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("socket app-server-control.sock present=False", events)
        self.assertIn("socket daemon-updater.sock present=False", events)

    def test_invalid_version_has_no_side_effects(self):
        result, events = self.run_case("--version", "invalid", MISSING_PACKAGES="bubblewrap")
        self.assertEqual(result.returncode, 2)
        self.assertEqual(events, [])


if __name__ == "__main__":
    unittest.main()
