#!/usr/bin/env python3
"""Builds build/demo.epub (the "Gospel Study Guide" notes book used by all
four GIF recordings) from fixtures/notes/. Run standalone, or via run.sh."""
import os
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "fixtures", "notes")
OUT_DIR = os.path.join(HERE, "build")
OUT = os.path.join(OUT_DIR, "demo.epub")


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    with zipfile.ZipFile(OUT, "w") as z:
        # mimetype must be first and stored (uncompressed) per the EPUB spec.
        z.write(os.path.join(SRC, "mimetype"), "mimetype", compress_type=zipfile.ZIP_STORED)
        for root, _dirs, files in os.walk(SRC):
            for name in files:
                if name == "mimetype":
                    continue
                full = os.path.join(root, name)
                arcname = os.path.relpath(full, SRC)
                z.write(full, arcname, compress_type=zipfile.ZIP_DEFLATED)
    print(f"built {OUT}")


if __name__ == "__main__":
    main()
