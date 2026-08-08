#!/usr/bin/env python3
"""Verify string-catalog coverage for compiler-extracted localizable strings.

The Candoa app target builds with SWIFT_EMIT_LOC_STRINGS, so every string
literal the compiler treats as localizable (Text, Label, Button,
String(localized:), ...) is written to a .stringsdata file in DerivedData.
This check fails when any extracted string is missing from
Candoa/Resources/Localizable.xcstrings, which is how uncataloged user-facing
copy would otherwise ship.

Usage: check-localization.py [--fix] [derived-data-path]
The path defaults to build/DerivedData (the CI build location). Run the
Debug build first; the check reads its .stringsdata output.

--fix rewrites the catalog the way Xcode's editor sync would: extracted
strings that are missing get new entries, and entries that no compiled
source references and that carry no translations are removed.
"""

import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
CATALOG = ROOT / "Candoa" / "Resources" / "Localizable.xcstrings"
APP_BUILD_DIR_NAME = "Candoa.build"


def fail(message: str) -> None:
    print(f"::error::{message}", file=sys.stderr)


def write_catalog(catalog: dict) -> None:
    # Match the catalog's existing style (two-space indent, " : " separators,
    # sorted keys) so Xcode rewrites stay minimal diffs.
    catalog["strings"] = dict(sorted(catalog["strings"].items()))
    body = json.dumps(catalog, ensure_ascii=False, indent=2, separators=(",", " : "))
    CATALOG.write_text(body + "\n")


def main() -> int:
    argv = sys.argv[1:]
    fix = "--fix" in argv
    argv = [arg for arg in argv if arg != "--fix"]
    derived_data = pathlib.Path(argv[0]) if argv else ROOT / "build" / "DerivedData"

    stringsdata_files = [
        path
        for path in derived_data.rglob("*.stringsdata")
        if APP_BUILD_DIR_NAME in path.parts
    ]
    if not stringsdata_files:
        fail(
            f"No .stringsdata found under {derived_data}. "
            "Run the Debug build first so the compiler emits localization data."
        )
        return 1

    catalog = json.loads(CATALOG.read_text())
    catalog_keys = set(catalog["strings"])

    missing: dict[str, str] = {}
    unknown_tables: set[str] = set()
    extracted_keys: set[str] = set()
    for path in stringsdata_files:
        data = json.loads(path.read_text())
        source = pathlib.Path(data.get("source", str(path)))
        try:
            source = source.relative_to(ROOT)
        except ValueError:
            pass
        for table, entries in data.get("tables", {}).items():
            if table != "Localizable":
                unknown_tables.add(table)
                continue
            for entry in entries:
                key = entry["key"]
                extracted_keys.add(key)
                if key in catalog_keys or key in missing:
                    continue
                line = entry.get("location", {}).get("startingLine", "?")
                missing[key] = f"{source}:{line}"

    for table in sorted(unknown_tables):
        fail(
            f"Strings were extracted into unexpected table {table!r}; "
            "Candoa catalogs all user-facing copy in Localizable.xcstrings."
        )

    stale = catalog_keys - extracted_keys
    if fix:
        for key in sorted(missing):
            catalog["strings"][key] = {}
        removed = 0
        for key in sorted(stale):
            if catalog["strings"][key].get("localizations"):
                print(
                    f"::warning::Keeping unreferenced key with translations: {key!r}",
                    file=sys.stderr,
                )
            else:
                del catalog["strings"][key]
                removed += 1
        write_catalog(catalog)
        print(
            f"Fixed catalog: added {len(missing)} missing keys, "
            f"removed {removed} unreferenced keys."
        )
        return 1 if unknown_tables else 0

    for key, location in sorted(missing.items()):
        fail(f"User-facing string missing from Localizable.xcstrings: {key!r} ({location})")

    for key in sorted(stale):
        print(
            f"::warning::Catalog key not referenced by compiled sources (stale?): {key!r}",
            file=sys.stderr,
        )

    print(
        f"Checked {len(extracted_keys)} extracted strings from "
        f"{len(stringsdata_files)} files against {len(catalog_keys)} catalog keys."
    )
    if missing or unknown_tables:
        return 1
    print("String-catalog coverage is complete.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
