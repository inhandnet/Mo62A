# tools

- `mo62a-factory/` — factory packaging helpers used by the flash tool.
- The board acceptance test tool (PySide6 GUI over SSH) has moved to
  [inhandnet/mo-tools](https://github.com/inhandnet/mo-tools/tree/master/board-test)
  (`board-test/`). It is released and versioned there; this repository keeps only
  the device-side `mo-discover` daemon in the rootfs overlay.
