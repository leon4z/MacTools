#!/usr/bin/env python3
"""Package a verified app and sign its ZIP/appcast with a dedicated Keychain key."""
import argparse
import datetime
import hashlib
import pathlib
import plistlib
import re
import subprocess
import tempfile
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parent.parent
SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
REPOSITORY = "https://github.com/leon4z/MacTools"
SIGNING_FINGERPRINT = "793D0DA7BCBFB6A0CDC8569A9F3E7A3D78A0C688"
ACCOUNT = "com.leon4z.MacTools"


def run(*args, **kwargs):
    return subprocess.run([str(a) for a in args], check=True, **kwargs)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--app", type=pathlib.Path, default=ROOT / "build/MacTools.app")
    args = parser.parse_args()
    app = args.app.resolve()
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    source_info = plistlib.loads((ROOT / "Resources/AppInfo.plist").read_bytes())
    for field in ("CFBundleVersion", "CFBundleShortVersionString", "CFBundleIdentifier", "SUPublicEDKey", "SUFeedURL"):
        if info[field] != source_info[field]:
            raise SystemExit(f"Built app differs from source: {field}")
    version, build = info["CFBundleShortVersionString"], info["CFBundleVersion"]
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", version) or not re.fullmatch(r"[0-9]+", build):
        raise SystemExit("Release requires numeric x.y.z version and numeric build.")
    requirement = f'identifier "com.leon4z.MacTools" and certificate leaf = H"{SIGNING_FINGERPRINT}"'
    run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=" + requirement, app)
    sparkle = pathlib.Path(run("bash", ROOT / "scripts/setup-sparkle.sh", capture_output=True, text=True).stdout.strip())
    public_key = run(sparkle / "bin/generate_keys", "--account", ACCOUNT, "-p", capture_output=True, text=True).stdout.strip()
    if public_key != info["SUPublicEDKey"]:
        raise SystemExit("Keychain update key does not match the embedded public key.")
    out = ROOT / "local/releases" / f"{version}-{build}"
    out.mkdir(parents=True, exist_ok=False)  # Never overwrite an already signed release.
    archive = out / f"MacTools-{version}-arm64.zip"
    run("/usr/bin/ditto", "-c", "-k", "--keepParent", "--norsrc", "--noextattr", app, archive)
    with tempfile.TemporaryDirectory(dir=out) as temp:
        run("/usr/bin/ditto", "-x", "-k", archive, temp)
        run("/usr/bin/codesign", "--verify", "--deep", "--strict", "-R=" + requirement, pathlib.Path(temp) / "MacTools.app")
    signature = run(sparkle / "bin/sign_update", "--account", ACCOUNT, "-p", archive, capture_output=True, text=True).stdout.strip()
    verifier = out / "verify-update"
    run("xcrun", "swiftc", "-target", "arm64-apple-macosx26.0", ROOT / "scripts/verify-update.swift", "-o", verifier)
    run(verifier, archive, signature, public_key)
    verifier.unlink()
    ET.register_namespace("sparkle", SPARKLE_NS)
    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = "MacTools Updates"
    ET.SubElement(channel, "link").text = REPOSITORY
    item = ET.SubElement(channel, "item")
    ET.SubElement(item, "title").text = f"MacTools {version}"
    ET.SubElement(item, "pubDate").text = datetime.datetime.now(datetime.timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")
    ET.SubElement(item, "description").text = f"MacTools {version}。完整更新说明：{REPOSITORY}/releases/tag/v{version}"
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = info["LSMinimumSystemVersion"]
    ET.SubElement(item, "enclosure", {
        "url": f"{REPOSITORY}/releases/download/v{version}/{archive.name}",
        "length": str(archive.stat().st_size), "type": "application/octet-stream",
        f"{{{SPARKLE_NS}}}version": build, f"{{{SPARKLE_NS}}}shortVersionString": version,
        f"{{{SPARKLE_NS}}}edSignature": signature,
    })
    feed = out / "mactools-appcast.xml"
    ET.indent(rss, space="  ")
    ET.ElementTree(rss).write(feed, encoding="utf-8", xml_declaration=True)
    run(sparkle / "bin/sign_update", "--account", ACCOUNT, feed)
    run(sparkle / "bin/sign_update", "--account", ACCOUNT, "--verify", feed)
    (out / "SHA256SUMS.txt").write_text("".join(
        f"{hashlib.sha256(path.read_bytes()).hexdigest()}  {path.name}\n" for path in (archive, feed)))
    print(out)


if __name__ == "__main__":
    main()
