# mini-enex — synthetic Evernote ENEX fixture

Public, deterministic fixture for `boris-migration-lab --mode=enex-inventory`
and `--mode=enex`. **Not** a real Evernote export; no real names, emails,
GPS coordinates, or URLs beyond `example.com`.

Shape follows Evernote ENEX exports: a directory (`--root=fixtures/mini-enex`)
containing two `.enex` notebook files. Every `<content>` CDATA block carries
the standard `<!DOCTYPE en-note SYSTEM "http://xml.evernote.com/pub/enml2.dtd">`
declaration; parsers must ignore DOCTYPE declarations and never fetch external
DTDs. Every non-dangling `<en-media hash="...">` holds the exact lowercase
32-hex MD5 digest of its decoded `<resource><data encoding="base64">` bytes.

## Layout

| Path | Role |
|------|------|
| `notebook.enex` | Primary notebook (`content/notebook.md` Trunk): two notes exercising standard ENML, checkboxes, matched PNG + plain-text resources, `<en-crypt>`, internal `evernote:///view/...` link, Boris-syntax neutralization, dangling `<en-media>`, and an unreferenced `<resource>` |
| `clips.enex` | Secondary notebook (`content/clips.md` Trunk): two notes exercising multi-notebook grouping, `<recognition>` OCR XML, a `<resource>` with no `<file-name>` (MIME-to-extension fallback), and a zero-tag baseline note |

## Notes and what each exercises

| File | Title | Exercises |
|------|-------|-----------|
| `notebook.enex` | `Architecture Overview` | Multiple `<tag>`s (`architecture`, `docs`); `<created>`/`<updated>` (`YYYYMMDDTHHMMSSZ`); `<note-attributes>` (`author`, `source`, `source-url`, synthetic `latitude`/`longitude` `0.0`, `reminder-order`); ENML `h1`–`h3`, `p`/`div`, `ul`/`ol`/`li`, `a`, `b`/`i`/`strong`/`em`, `code`/`pre`, `blockquote`, `table`; `<en-todo checked="true"/>` and `<en-todo checked="false"/>`; `<en-media type="image/png" hash="78dc75bbdaf576f1f4f214d0f0f1b1ea"/>` matching `diagram.png` (exact bytes of `fixtures/absolute-links-astro/public/images/hero.png`); `<en-media type="text/plain" hash="d16d8ec1f1e82c2e97702fbf474c903d"/>` matching `notes.txt` |
| `notebook.enex` | `Encrypted and Internal Links` | Single `<tag>` (`review`); `<content-class>` attribute; internal `evernote:///view/...` link (`human_review`); literal Boris syntax (`[[not-a-wikilink]]`, `{{not-an-include}}`, `<Aside kind="note">...</Aside>`) for neutralization; `<en-crypt hint="synthetic-hint">` with placeholder base64 (`human_review`, never decrypted); dangling `<en-media hash="deadbeefdeadbeefdeadbeefdeadbeef"/>` (`human_review`); unreferenced `application/pdf` `<resource>` (`orphan-handout.pdf`, MD5 `bf9d6d007add12db4be03a82c7e70f83`, `human_review`) |
| `clips.enex` | `Web Clip with OCR Scan` | Multi-notebook grouping (`clips.enex`); `<source>web.clip</source>`, `<source-url>`, `<content-class>`; `<resource>` (`scan.png`, MD5 `912a61bf3c65883bc23d60d4fade3f21`) carrying `<recognition>` OCR `recoIndex` XML; `<resource>` (`image/jpeg`, MD5 `6e0acc08d8e594291c82676e09b12aa4`) with no `<file-name>` to exercise MIME-to-extension fallback naming |
| `clips.enex` | `Quick Capture` | Zero `<tag>` elements; minimal `<note-attributes>`; clean ENML `<p>` body with no attachments or review triggers |

## Expected conversion signals

- Multi-notebook input produces two Trunk stubs (`content/notebook.md`,
  `content/clips.md`) and four flat Satellite pages (`parent: notebook` or
  `parent: clips`)
- Every non-dangling `<en-media hash>` matches
  `MD5(base64_decode(resource.data))`:
  - `78dc75bbdaf576f1f4f214d0f0f1b1ea` (`diagram.png`, `hero.png` bytes)
  - `d16d8ec1f1e82c2e97702fbf474c903d` (`notes.txt`)
  - `912a61bf3c65883bc23d60d4fade3f21` (`scan.png`, with `<recognition>` OCR XML)
  - `6e0acc08d8e594291c82676e09b12aa4` (unnamed `image/jpeg`)
- Dangling `<en-media>` (`deadbeefdeadbeefdeadbeefdeadbeef`), unreferenced
  `orphan-handout.pdf`, `<en-crypt>`, and `evernote:///view/...` all trigger
  `human_review`
- See `docs/contracts/enex.md` for the construct disposition table
