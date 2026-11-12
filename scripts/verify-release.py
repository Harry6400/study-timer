#!/usr/bin/env python3
"""校验 Mac 下载包的哈希、架构、版本、签名与 DMG 内容。"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("directory", type=Path)
parser.add_argument("--version", required=True)
args = parser.parse_args()
root = args.directory.resolve()
assets = ["StudyTimer-macOS-arm64.dmg", "StudyTimer-macOS-arm64.zip"]
checksums = {}
for line in (root / "SHA256SUMS.txt").read_text().splitlines():
    digest, name = line.split(maxsplit=1)
    checksums[name.lstrip(" *")] = digest
if set(checksums) != set(assets):
    raise SystemExit("校验文件必须且仅包含 DMG 和 ZIP")
for name in assets:
    if hashlib.sha256((root / name).read_bytes()).hexdigest() != checksums[name]:
        raise SystemExit("SHA-256 不一致：" + name)
with zipfile.ZipFile(root / assets[1]) as archive:
    if archive.testzip() is not None:
        raise SystemExit("ZIP 内容损坏")
    for name in archive.namelist():
        if name.startswith("/") or ".." in Path(name).parts:
            raise SystemExit("ZIP 中存在不合法路径")
        if not name.startswith(("StudyTimer.app/", "__MACOSX/")):
            raise SystemExit("ZIP 中包含非应用文件：" + name)

with tempfile.TemporaryDirectory(prefix="StudyTimer-verify-") as temporary:
    temporary = Path(temporary)
    subprocess.run(["ditto", "-x", "-k", str(root / assets[1]), str(temporary)], check=True)
    app = temporary / "StudyTimer.app"
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    expected = {"CFBundleIdentifier": "local.harry64.studytimer", "CFBundleShortVersionString": args.version.removeprefix("v"), "LSMinimumSystemVersion": "26.0"}
    for key, value in expected.items():
        if info.get(key) != value:
            raise SystemExit("应用元数据不一致：" + key)
    if "StudyTimerVerificationDirectory" in info:
        raise SystemExit("发布包中不应包含演示数据目录配置")
    binary = app / "Contents/MacOS/StudyTimer"
    arch = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).strip()
    if arch != "arm64":
        raise SystemExit("发布包架构必须为 arm64，实际：" + arch)
    license_text = (app / "Contents/Resources/LICENSE.txt").read_text()
    if "MIT License" not in license_text or "Harry6400" not in license_text:
        raise SystemExit("应用内许可证缺失或不正确")
    if not os.access(binary, os.X_OK):
        raise SystemExit("应用可执行文件权限丢失")
    subprocess.run(["codesign", "--verify", "--strict", str(app)], check=True)
    subprocess.run(["hdiutil", "verify", str(root / assets[0])], check=True)
    mount = temporary / "mounted"
    mount.mkdir()
    attached = False
    try:
        subprocess.run(["hdiutil", "attach", "-readonly", "-nobrowse", "-mountpoint", str(mount), str(root / assets[0])], check=True)
        attached = True
        if not (mount / "Applications").is_symlink() or os.readlink(mount / "Applications") != "/Applications":
            raise SystemExit("DMG 缺少 Applications 快捷入口")
        dmg_app = mount / "StudyTimer.app"
        subprocess.run(["codesign", "--verify", "--strict", str(dmg_app)], check=True)
        if hashlib.sha256((dmg_app / "Contents/MacOS/StudyTimer").read_bytes()).digest() != hashlib.sha256(binary.read_bytes()).digest():
            raise SystemExit("DMG 与 ZIP 的应用可执行文件不同")
        if (dmg_app / "Contents/Resources/LICENSE.txt").read_text() != license_text:
            raise SystemExit("DMG 与 ZIP 许可证不同")
    finally:
        if attached:
            subprocess.run(["hdiutil", "detach", str(mount)], check=True)
print(json.dumps({"version": args.version.removeprefix("v"), "architecture": "arm64", "minimum_macos": "26.0", "assets": assets, "sha256": "ok", "signature_integrity": "ok", "apple_notarization": False}, ensure_ascii=False, indent=2))
