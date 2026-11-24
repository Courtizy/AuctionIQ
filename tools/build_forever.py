"""Builds the whole WoW: Forever install of AuctionIQ, so a deploy is never a few changed files.

    python3 tools/build_forever.py [out_dir]     (default: dist)

Writes <out_dir>/AuctionIQ/ with every file AuctionIQ_Camelot.toc lists, the in-game media, the
Camelot TOC and a plain AuctionIQ.toc copy of it, and <out_dir>/AuctionIQ-forever-<version>.zip.
@project-version@ becomes the build's version from git, for example 0.0.0-212-g90a5683, so
/aiq game names the exact commit. CI runs this on every push and keeps the zip as an artifact."""
import shutil
import subprocess
import sys
import zipfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def version():
    def git(*a):
        return subprocess.run(["git", *a], cwd=ROOT, capture_output=True, text=True).stdout.strip()
    tag = git("describe", "--tags", "--match", "v*", "--abbrev=0")
    base = tag.lstrip("v") if tag else "0.0.0"
    count = git("rev-list", "--count", (tag + "..HEAD") if tag else "HEAD") or "0"
    sha = git("rev-parse", "--short=7", "HEAD") or "unknown"
    dirty = "-dirty" if git("status", "--porcelain", "--untracked-files=no") else ""
    return f"{base}-{count}-g{sha}{dirty}"


def files():
    toc = (ROOT / "AuctionIQ_Camelot.toc").read_text().splitlines()
    lua = [l.strip().replace("\\", "/") for l in toc if l.strip().endswith(".lua")]
    media = sorted(p.relative_to(ROOT).as_posix() for p in (ROOT / "Media").glob("*.tga"))
    return lua + media


def build(out):
    v = version()
    dest = out / "AuctionIQ"
    shutil.rmtree(dest, ignore_errors=True)
    for f in files():
        target = dest / f
        target.parent.mkdir(parents=True, exist_ok=True)
        if f.endswith(".lua"):
            target.write_text((ROOT / f).read_text().replace("@project-version@", v))
        else:
            shutil.copy2(ROOT / f, target)
    toc = (ROOT / "AuctionIQ_Camelot.toc").read_text().replace("@project-version@", v)
    (dest / "AuctionIQ_Camelot.toc").write_text(toc)
    (dest / "AuctionIQ.toc").write_text(toc)  # Forever loads this if it ever skips the _Camelot one
    z = out / f"AuctionIQ-forever-{v}.zip"
    with zipfile.ZipFile(z, "w", zipfile.ZIP_DEFLATED) as zf:
        for p in sorted(dest.rglob("*")):
            if p.is_file():
                zf.write(p, p.relative_to(out).as_posix())
    return v, dest, z


if __name__ == "__main__":
    v, dest, z = build(Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "dist")
    print(f"AuctionIQ {v}: {dest} and {z}")
