# viber-export-macos

Export **your own** Viber Desktop chat history to CSV on macOS (Apple Silicon or Intel).

Viber Desktop for macOS stores its message database (`viber.db`) encrypted with a **custom
AES SQLite codec** — not SQLCipher. As a result, DB Browser for SQLite, the `sqlite3` CLI,
and every popular Python "Viber extractor" fail on it with `file is not a database`. The
decryption key is derived at runtime and never written to disk.

This script gets your messages out anyway — **entirely locally**, with no Windows VM, no
cloud upload, and without modifying your Viber installation.

```bash
chmod +x viber-export-macos.sh
./viber-export-macos.sh            # writes ~/Desktop/viber_export.csv
```

---

## ⚠️ Use on your own data only

This tool re-signs a throwaway copy of Viber for debugging and reads the key out of the
running process. Only use it on **your own Mac, your own Viber account, and your own
messages.** You are responsible for complying with the law and Viber's terms in your
jurisdiction. It is **not** a way to access anyone else's messages.

---

## Requirements

- **macOS** with **Viber Desktop** installed and **signed in** (it must be able to open
  `viber.db` on launch).
- **Xcode Command Line Tools** — provides `lldb`, `codesign`, `python3`.
  If missing, the script offers to run the installer for you (`xcode-select --install`).
- Works with **SIP enabled** and **Developer Mode off** — no system changes required.
- Targets Viber builds based on **Qt 6** (all current versions). See [Caveat](#caveat--compatibility).

## Usage

```
./viber-export-macos.sh [-o OUTPUT_DIR] [-a /path/to/Viber.app] [-y]

  -o OUTPUT_DIR   where to write the outputs   (default: ~/Desktop)
  -a VIBER_APP    path to Viber.app            (default: /Applications/Viber.app)
  -y              assume "yes"; required for non-interactive / CI-style runs

Environment:
  VIBER_DB=/path/to/viber.db   skip auto-detection (e.g. multiple accounts)
```

A Viber window will briefly appear while the script captures the key, then it closes
itself. Typical run time is 1–3 minutes. On APFS the app copy is an instant
copy-on-write clone, so it takes no extra disk space.

> **iCloud Drive:** if *Desktop & Documents Folders* is on in iCloud Drive, `~/Desktop`
> (the default output) is uploaded to iCloud. The script detects this and asks before
> writing there. To keep the decrypted chats on this Mac, use a local folder:
> `./viber-export-macos.sh -o ~/viber-export`

## Output

- **`viber_export.csv`** — UTF-8 with a BOM (so Excel/Numbers show Cyrillic, emoji, etc.
  correctly), one row per message:

  | Column | Meaning |
  |---|---|
  | `DateTime` | Local time of the message |
  | `ChatID` | Conversation id (groups vs 1:1) |
  | `Contact` | Sender/peer name, else phone number, else `ContactID:<n>` |
  | `Direction` | `received` or `sent` |
  | `MsgType` | Viber message type (`0` = text) |
  | `Message` | Message body |

  > Numeric `Message` values with `MsgType != 0` are media/sticker **token IDs**, not text.

- **`viber_plain.db`** — a fully decrypted, plaintext SQLite copy (`Messages`, `Events`,
  `Contact`). Query it directly if you want more than the default CSV, e.g.:

  ```bash
  sqlite3 viber_plain.db "SELECT count(*) FROM Messages;"
  ```

## How it works

Everything happens on your machine, in your user session:

1. **Debuggable copy.** Copies `Viber.app` to a temp dir and ad-hoc re-signs it with
   `get-task-allow` (hardened runtime removed). Your installed Viber is never touched.
2. **Capture the key at runtime.** Launches the copy under `lldb`, breakpoints Qt's SQL
   layer, and records the `PRAGMA hexkey=...` statements Viber issues to unlock `viber.db`
   (a per-device key plus a cipher-select string). **Nothing is hardcoded** — this adapts
   to any user/device, and to a one- or two-`hexkey` sequence.
3. **Decrypt via Viber's own codec.** From inside the same process, opens an *independent*
   connection to `viber.db` through Viber's codec, applies the captured keys, and copies
   the message tables into a brand-new **plaintext** database with `ATTACH ... KEY ''`.
4. **CSV.** Runs a join over `Events`, `Messages`, and `Contact` and writes the CSV.

## Data safety & what it touches

- **The tool's own database access is read-only.** Its export opens `viber.db` on a
  separate, read-only connection; all of *its* writes go to a temp working directory
  (auto-deleted, `0700`) and to your chosen output files.
- **It does launch a real (copied) Viber instance**, though. That instance is a normal
  Viber client, so as it starts and syncs it may read/write your live `viber.db` just like
  the app always does. When the export is done the script force-terminates that copy;
  because `viber.db` is WAL-journaled (crash-safe — see [Glossary](#glossary)), SQLite
  recovers cleanly even from a hard stop. For zero risk, **quit Viber before running** (the
  script warns if it's open). Your Viber *application bundle* is never modified; only a
  throwaway copy is.
- **Your outputs are unencrypted private messages.** `viber_plain.db` and
  `viber_export.csv` contain your full chat history in the clear. The script writes them
  `0600` (owner-only), but you should still store them somewhere safe and delete them when
  done.
- **It re-signs a copy of Viber** (ad-hoc, hardened-runtime removed, `get-task-allow`) so
  `lldb` can debug it. This is expected for the technique, but antivirus / EDR / Gatekeeper
  heuristics may flag the re-signed copy or the `lldb` attach. Nothing leaves your machine.
- **No key material is ever persisted.** The captured key is used only in memory; the
  status marker records only a success/error code, and any diagnostic log saved on failure
  has `hexkey='...'` values redacted.

## Caveat / compatibility

The one thing that can break this tool: it depends on Viber being built on **Qt 6** and
unlocking the database via `PRAGMA hexkey`, and it calls specific Qt SQL functions by their
C++ mangled names. **If a future Viber ships a different Qt major version or renames those
functions, the injection can't work.**

To keep this from failing in a confusing way, the script **checks for exactly this at
startup** — before copying or launching anything — by verifying the required symbols exist
in Viber's bundled `QtCore`/`QtSql`. If they're missing, it stops immediately with the
detected Qt version and the exact missing symbols, and changes nothing.

If that happens, update the symbol list to match your Viber's Qt build. The names live in
**two clearly-marked, kept-in-sync places** near the top of the script:

- `QT_REQUIRED_SYMS_CORE` / `QT_REQUIRED_SYMS_SQL` (the shell preflight)
- the `SYMS` dictionary inside the embedded Python (the actual lldb injection)

Find the current names with, e.g.:

```bash
nm -gU "/Applications/Viber.app/Contents/Frameworks/QtSql.framework/Versions/A/QtSql" \
  | grep -E 'QSqlQuery|QSqlDatabase' | c++filt
```

## Troubleshooting

Every failure stops with a `[STOPPED]` message explaining **why** and **what to do**. Common ones:

| Symptom | Cause / fix |
|---|---|
| *Xcode Command Line Tools are required* | Run `xcode-select --install`, finish the dialog, re-run. |
| *Timed out before Viber unlocked its database* | Make sure Viber is **signed in** and online; complete any login/QR prompt, then re-run. |
| *lldb was not allowed to launch/debug Viber* | Run `sudo DevToolsSecurity -enable`, then re-run. |
| *Qt SQL interface does not match…* | Viber's Qt build changed — see [Caveat](#caveat--compatibility). |
| *Viber is currently running* | Quit Viber (⌘Q); the script waits up to 60 s for it to close. Or pass `-y` to proceed anyway. |
| *Re-signing the Viber copy failed* | The message quotes codesign's error. Stray files in the `Viber.app` root (e.g. `manifest.md5`) and Finder xattrs are already stripped from the copy automatically. |
| *output folder is synced to iCloud Drive* | Re-run with `-o` pointing at a local folder, e.g. `-o ~/viber-export`. |
| *No `Messages` table…* | Your Viber schema differs; inspect `viber_plain.db` with `sqlite3 … .tables`. |

When something goes wrong during the lldb phase, the script saves a **key-redacted**
`viber-export-debug.log` in your output directory and points you at it.

## Glossary

If some of the terms above are unfamiliar, here's what they mean in this context.

### Viber & its data
- **Viber Desktop** — the macOS Viber app. It keeps a local copy of your chats so they're
  available offline.
- **`viber.db`** — the single file where Viber Desktop stores your messages, contacts, and
  call log. It lives in `~/Library/Application Support/ViberPC/<your-phone-number>/`.
- **ViberPC folder** — that `~/Library/Application Support/ViberPC/` directory; the
  `<phone-number>` subfolder holds one account's data.
- **QR sync** — how Viber Desktop links to your phone: you scan a QR code, and your phone
  pushes your history to the desktop. The desktop must be signed in this way for its
  `viber.db` to exist and be unlockable.

### Databases & SQLite
- **SQLite** — a tiny, self-contained database engine that stores an entire database in one
  ordinary file. Countless apps (including Viber) embed it. A `.db` file is usually SQLite.
- **CSV** (Comma-Separated Values) — a plain-text spreadsheet format: one row per line,
  fields separated by commas. Opens in Excel, Numbers, Google Sheets, etc.
- **Schema / table** — the structure of a database. Viber's data is split across tables;
  this tool reads three: **`Messages`** (the text/bodies), **`Events`** (timestamp,
  direction, which chat), and **`Contact`** (names and numbers). A join stitches them back
  together into readable rows.
- **PRAGMA** — a special SQLite command that changes a setting or runs a maintenance action
  (rather than reading data). For example `PRAGMA journal_mode=WAL;`.
- **`PRAGMA hexkey='…'`** — the specific command Viber uses to hand the encrypted database
  its decryption key, given as a hex (base-16) string. Capturing these is the crux of this
  tool.
- **`ATTACH DATABASE … / DETACH DATABASE`** — SQLite commands that open a *second* database
  file alongside the current one so you can copy data between them. This tool `ATTACH`es a
  brand-new file with `KEY ''` (empty key = unencrypted) and copies the tables into it,
  producing the plaintext `viber_plain.db`.
- **WAL** (Write-Ahead Logging) — a SQLite mode where changes are first written to a
  side-file (`viber.db-wal`, with `viber.db-shm` as a shared-memory index) and later folded
  into the main file. Its key property here: it's **crash-safe** — if a process is killed
  mid-write, SQLite rolls the database back to a consistent state on next open.
- **SQLCipher** — the *usual* open-source extension that encrypts SQLite databases; many
  tools know how to open it. Viber does **not** use it — it uses its own custom AES codec,
  which is exactly why off-the-shelf tools fail.

### Encryption
- **AES** (Advanced Encryption Standard) — the standard, widely-trusted symmetric cipher
  used to encrypt/decrypt data with a secret key. Viber encrypts `viber.db` with it.
- **Codec / cipher** — the code that does the encrypting and decrypting. Viber's is
  "custom" meaning it's their own implementation rather than a public standard like
  SQLCipher, so only Viber (or this tool, borrowing Viber's own code) can read the file.
- **Key derivation** — turning a stored secret into the actual encryption key. Viber derives
  its key at runtime from device-specific data, so the key isn't sitting in a file to copy —
  it has to be captured from the running app.

### Qt (the toolkit Viber is built with)
- **Qt** — a popular C++ framework for building cross-platform desktop apps; Viber Desktop
  is a **Qt 6** app. Qt ships as a set of libraries called *frameworks* on macOS.
- **QtCore / QtSql** — two of those Qt frameworks. `QtCore` has fundamental types (e.g.
  `QString`, Qt's text type); `QtSql` is Qt's database layer. This tool calls functions in
  both.
- **`QSqlDatabase` / `QSqlQuery`** — the Qt classes for opening a database connection and
  running SQL. The tool drives these directly to open its own connection and run the copy.
- **Mangled name / C++ symbol** — C++ compilers encode a function's full signature into a
  cryptic name (e.g. `_ZN9QSqlQuery4execERK7QString` = `QSqlQuery::exec(const QString&)`).
  The tool locates Qt's functions by these names; that's the fragile part the startup check
  guards (see [Caveat](#caveat--compatibility)). `c++filt` turns a mangled name back into a
  readable one.

### macOS & debugging tools
- **lldb** — the debugger that ships with Xcode. It can pause a program, read its memory,
  and even call functions inside it — which is how this tool captures the key and runs the
  export from *inside* Viber.
- **Apple Silicon vs Intel** — the two Mac CPU types (ARM64 M-series vs x86-64). Function
  arguments live in different CPU registers on each, so the tool detects which it's on.
- **Rosetta** — Apple's translation layer that runs Intel apps on Apple Silicon; the tool
  handles a Viber running under it too.
- **Xcode Command Line Tools** — Apple's free developer toolkit (provides `lldb`,
  `codesign`, `python3`, etc.). Install with `xcode-select --install`.
- **codesign / ad-hoc signing / entitlements** — macOS requires apps to be cryptographically
  *signed*. "Ad-hoc" signing re-signs an app locally without a developer certificate.
  *Entitlements* are permissions baked into the signature.
- **`get-task-allow`** — the one entitlement this tool adds to its Viber *copy*: it permits a
  debugger to attach. Normal shipping apps omit it, which is why a re-signed copy is needed.
- **Hardened Runtime** — a macOS security mode that (among other things) blocks debuggers.
  The tool removes it from the throwaway copy so `lldb` can attach.
- **SIP** (System Integrity Protection) — a macOS protection that locks down system files
  and processes. This tool works with SIP **on** — no need to disable it.
- **Developer Mode / `DevToolsSecurity`** — a macOS toggle for allowing debugging. Usually
  not required here (the `get-task-allow` copy suffices); the failure message points to
  `sudo DevToolsSecurity -enable` only if a launch is ever blocked.
- **Gatekeeper** — the macOS feature that checks app signatures on launch; a re-signed copy
  or AV/EDR heuristics may notice it.
- **`nm` / `otool`** — command-line tools that inspect a binary's symbols (`nm`) and its
  linked libraries/versions (`otool`). The startup check uses them to verify Viber's Qt.
- **`umask` / `chmod 600`** — controls file permissions. `chmod 600` / a `077` umask make a
  file readable only by you — used here so your decrypted exports aren't world-readable.
- **SIGTERM / SIGKILL** — Unix signals to stop a process: `SIGTERM` asks politely (can be
  handled), `SIGKILL` is an immediate, unstoppable stop.

## License

[MIT](LICENSE).
