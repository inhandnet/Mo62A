#!/usr/bin/env python3
"""Generate a deterministic SPDX 2.3 SBOM for a Mo62A release image.

The package list comes from the dpkg database of the assembled root filesystem
(copied out of the read-only mounted image by verify-image.sh). The kernel built
from this repository is added as its own package. Files that are installed
outside dpkg, such as the TI EdgeAI runtime under /opt/ti, are not listed; the
document says so in its creation comment.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import sys

VERSION = re.compile(r"^V(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
NAMESPACE = "https://github.com/inhandnet/Mo62A/releases/download"


def parse_status(text):
    """Return installed packages from a dpkg status file, sorted by name and architecture."""
    packages = []
    for block in re.split(r"\n\s*\n", text.strip()):
        fields, key = {}, None
        for line in block.splitlines():
            if line[:1] in (" ", "\t") and key:
                continue  # continuation lines (descriptions, conffiles) are not needed
            if ":" in line:
                key, value = line.split(":", 1)
                fields[key.strip()] = value.strip()
        if not fields.get("Package"):
            continue
        if fields.get("Status", "").split()[-1:] != ["installed"]:
            continue
        packages.append(fields)
    if not packages:
        raise ValueError("No installed packages found in the dpkg status file")
    packages.sort(key=lambda p: (p["Package"], p.get("Architecture", "")))
    return packages


def spdx_id(*parts):
    return "SPDXRef-" + re.sub(r"[^A-Za-z0-9.-]", "-", "-".join(parts))


def purl(fields):
    name, version = fields["Package"], fields.get("Version", "")
    arch = fields.get("Architecture", "")
    value = f"pkg:deb/debian/{name}@{version}"
    return value + (f"?arch={arch}" if arch else "")


def build(version, image_name, kernel, created, status_text):
    if not VERSION.fullmatch(version):
        raise ValueError(f"Invalid release version: {version}")
    if not re.fullmatch(r"\d{4}-\d{2}-\d{2}", created):
        raise ValueError("Creation date must be YYYY-MM-DD")
    if not kernel or not re.fullmatch(r"[A-Za-z0-9._+-]+", kernel):
        raise ValueError("Invalid kernel release")
    packages = parse_status(status_text)
    image_id = spdx_id("Image", image_name)
    kernel_id = spdx_id("Kernel", kernel)
    seen = {image_id, kernel_id}
    rows = [
        {"SPDXID": image_id, "name": image_name, "versionInfo": version,
         "supplier": "Organization: InHand Networks", "downloadLocation": f"{NAMESPACE}/{version}/{image_name}",
         "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION",
         "copyrightText": "NOASSERTION", "primaryPackagePurpose": "OPERATING-SYSTEM"},
        {"SPDXID": kernel_id, "name": "linux", "versionInfo": kernel,
         "supplier": "Organization: InHand Networks", "downloadLocation": f"https://github.com/inhandnet/Mo62A/tree/{version}",
         "filesAnalyzed": False, "licenseConcluded": "NOASSERTION", "licenseDeclared": "GPL-2.0-only",
         "copyrightText": "NOASSERTION", "primaryPackagePurpose": "OPERATING-SYSTEM"},
    ]
    relationships = [
        {"spdxElementId": "SPDXRef-DOCUMENT", "relationshipType": "DESCRIBES", "relatedSpdxElement": image_id},
        {"spdxElementId": image_id, "relationshipType": "CONTAINS", "relatedSpdxElement": kernel_id},
    ]
    for fields in packages:
        ident = spdx_id("Package", fields["Package"], fields.get("Architecture", ""))
        if ident in seen:
            raise ValueError(f"Duplicate package entry: {fields['Package']}")
        seen.add(ident)
        row = {"SPDXID": ident, "name": fields["Package"], "versionInfo": fields.get("Version", "NOASSERTION"),
               "supplier": "Organization: Debian" if "debian" in fields.get("Maintainer", "").lower()
               else "NOASSERTION",
               "downloadLocation": "NOASSERTION", "filesAnalyzed": False,
               "licenseConcluded": "NOASSERTION", "licenseDeclared": "NOASSERTION", "copyrightText": "NOASSERTION",
               "externalRefs": [{"referenceCategory": "PACKAGE-MANAGER", "referenceType": "purl",
                                 "referenceLocator": purl(fields)}]}
        if fields.get("Homepage"):
            row["homepage"] = fields["Homepage"]
        if fields.get("Source"):
            row["sourceInfo"] = f"Debian source package: {fields['Source']}"
        rows.append(row)
        relationships.append({"spdxElementId": image_id, "relationshipType": "CONTAINS", "relatedSpdxElement": ident})
    digest = hashlib.sha256(status_text.encode()).hexdigest()[:16]
    return {
        "spdxVersion": "SPDX-2.3", "dataLicense": "CC0-1.0", "SPDXID": "SPDXRef-DOCUMENT",
        "name": f"Mo62A {version} image SBOM",
        "documentNamespace": f"{NAMESPACE}/{version}/sbom-{digest}",
        "creationInfo": {"created": f"{created}T00:00:00Z", "creators": ["Tool: Mo62A scripts/sbom.py",
                                                                        "Organization: InHand Networks"],
                         "comment": "Packages are read from the image dpkg database. Files installed outside "
                                    "dpkg, such as the TI EdgeAI runtime under /opt/ti, are not listed."},
        "packages": rows, "relationships": relationships,
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--version", required=True)
    parser.add_argument("--image-name", required=True)
    parser.add_argument("--kernel", required=True)
    parser.add_argument("--date", required=True, help="Source commit date, YYYY-MM-DD")
    parser.add_argument("--dpkg-status", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    document = build(args.version, args.image_name, args.kernel, args.date,
                     args.dpkg_status.read_text(encoding="utf-8"))
    args.output.write_text(json.dumps(document, ensure_ascii=False, indent=1) + "\n")
    print(f"SBOM: {len(document['packages'])} packages -> {args.output}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError) as exc:
        sys.exit(f"SBOM generation: {exc}")
