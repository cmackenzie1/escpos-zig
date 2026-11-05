# escpos-zig 0.2.0

Changes since 0.1.0. This release has **breaking changes**, all aimed at
making it harder to send unintended printer commands or mismatched text by
accident.

## Breaking changes

### Text methods filter control bytes (#21)

`Printer.text`, `line`, `columns` and `rule` now drop control bytes (ESC, GS,
DLE, FS, DEL and every other byte below `0x20`) so an untrusted string can no
longer inject printer commands such as cutting the paper or pulsing the cash
drawer. Line feed and tab survive in `text` and `line`; `columns` drops
those too. Bytes `0x80` and above are untouched, since they print as glyphs.

- **New:** `Printer.raw(bytes)` writes bytes exactly as given. It is the only
  unfiltered path. The CLI's `--encoding raw` uses it.
- **Removed:** `Printer.print`. It formatted arguments straight to the writer,
  so `{s}` arguments bypassed filtering. Format into a buffer and pass the
  result to `text`.
- `columns` pads using the filtered length. `rule` replaces a control byte
  passed as `ch` with `-`.

**Migrating:** code that deliberately sent command bytes through `text` or
`line` must switch to `raw`. Prefer the typed methods (`setBold`, `cut`, ...).

### `textUtf8` and `lineUtf8` select their own code page (#22)

Both now emit `ESC t` for the given `Encoding` before the text. Previously
callers had to call `setEncoding` with the same value first, and a mismatch,
or an `initialize` in between (ESC @ resets the page), printed wrong glyphs
silently. The cost is 3 extra bytes per call, so output bytes change.
`setEncoding` remains for high bytes sent through `text`, `line` or `raw`.

## New

- **ASCII fallback for typographic punctuation** (#19). Characters the
  selected code page lacks no longer print as `?` (new `src/punctuation.zig`):
  - `‘ ’ ‚ ‛ ′` → `'`
  - `“ ” „ ‟ ″ « »` → `"`
  - `‐ ‑ ‒ – −` → `-`; `— ―` → `--`
  - `…` → `...`
  - non-breaking and other special spaces (U+00A0, U+2002–U+200A, U+202F,
    U+205F, U+3000) → space
  - `• ‣ ◦ ∙` → `*`; `·` → `.`; `×` → `x`; `÷` → `/`; `™` → `(TM)`
  - zero-width characters and the soft hyphen are dropped

  The code page is tried first, so cp1252 keeps real curly quotes (`’` is
  still `0x92`) and cp437/cp858 keep `«` and `•` where they exist. Characters
  with no stand-in, such as CJK, still print `?`. U+00A0 is always written as a
  plain space.
- **Control-byte filtering in `textUtf8`** (#19): control characters other
  than line feed and tab are dropped.

## Fixes

- `image.scale` could overflow its `u32` accumulator, panicking in safe
  builds, when a box-filter cell covered more than about 16.8M source pixels.
  It now uses `u64` (#20).
- The CLI now validates PDF417 data length (1–65532 bytes) before touching the
  printer, instead of failing mid-job with an error trace (#20).
- `setSize` documents that out-of-range values are clamped (#20).
