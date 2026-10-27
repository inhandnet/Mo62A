# Release hardware validation

A tag builds the image and leaves the GitHub Release as a **draft**. The draft
image itself is flashed to a microSD card with the default `sysconfig.txt`,
booted on a board and tested. The result is committed here as
`<version>.json`, then the **Publish validated release** workflow checks the
record against the draft, adds it to `release.json` (`validation.hardware`)
and `SHA256SUMS`, attaches it as `validation.json` and publishes the release.
Published releases are never rewritten.

The record must describe the exact draft: same version, source commit, image
name and SHA-256, and kernel. Write only what was observed. `result` is
`failed` exactly when one test failed; skipped tests say why.

```json
{
  "version": "V1.1.1",
  "commit": "<40-character source commit of the tag>",
  "image": {"name": "mo62a-trixie-xfce-V1.1.1.img.xz", "sha256": "<from the draft SHA256SUMS>"},
  "kernel": "<uname -r on the board>",
  "board": "Mo62A PCB V1.1, 4 GB",
  "date": "2026-10-27",
  "tester": "<name or team>",
  "result": "passed",
  "companions": {"mo-tools": "V1.0.0", "mo-models": "V1.0.0", "mo-examples": "V1.0.0"},
  "tests": [
    {"id": "boot", "item": "Boots from the default sysconfig.txt to the desktop", "result": "passed", "evidence": "..."}
  ]
}
```

`companions` lists the mo-tools, mo-models and mo-examples releases used in
the test. Those repositories list this image in their own `images` fields after
it is published.

## Checklist

Each release covers at least these items, plus one item for every board-side
change since the previous release.

| Area | Item |
|---|---|
| Image | Draft image SHA-256 matches `SHA256SUMS`; flashed with the default `sysconfig.txt` |
| Boot | Boots to the XFCE desktop; `uname -r` and `/etc/os-release` match `release.json` |
| First boot | Hostname, user and network come from `sysconfig.txt`; hostname is set before mDNS and login |
| Login | SSH login with the configured user; discovery answers with the address on the requester route |
| Network | Ethernet link and throughput; Wi-Fi scan and connect; Bluetooth controller up |
| Display and audio | HDMI output; analog and HDMI audio sinks have distinct names |
| Camera and video | IMX219 detected with the camera overlay; H.264 decode starts without timeout |
| AI | `edgeai-demo` status and one NPU demo run on the C7x |
| Companions | mo-tools board test, one mo-models model and one mo-examples example run on this image |
| Security | SBOM attached to the draft; OP-TEE and the crypto devices are present as documented |
