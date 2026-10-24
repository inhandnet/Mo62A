# Board boot-test records

`scripts/release.py` reports `validation.hardwareBootTest` in `release.json`
from a record in this directory named `<version>.json`. Without a record the
release says the boot test is not recorded. The record must describe the exact
release source, otherwise the release fails:

```json
{
  "version": "V1.1.1",
  "commit": "<40-character source commit the tag points to>",
  "kernel": "<kernel release printed by the build, e.g. 6.12.35-ti-rt>",
  "board": "Mo62A rev V1.1, 4 GB",
  "image_name": "mo62a-trixie-xfce-V1.1.1.img.xz",
  "date": "2026-10-30",
  "result": "passed",
  "tester": "<name or team>",
  "method": "flashed to microSD, booted to desktop, SSH login, LED and serial console checked"
}
```

`result` is `passed` or `failed`. The whole record is copied into
`release.json` as `validation.hardwareBootTestEvidence`, so write only what
was actually observed. Published releases are never rewritten; a record added
later applies to the next version.
