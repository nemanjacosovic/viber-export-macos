#!/usr/bin/env bash
#
# viber-export-macos.sh  —  Export your OWN Viber Desktop chat history to CSV on macOS.
# =====================================================================================
#
# WHY
#   Viber Desktop for macOS encrypts viber.db with a *custom* AES SQLite codec (NOT
#   SQLCipher). DB Browser / sqlite3 / the usual Python extractors all fail with
#   "file is not a database". The key is derived at runtime and never stored on disk.
#
# HOW (100% local; no cloud, no Windows VM)
#   1. Makes a throwaway, ad-hoc-signed *debuggable* copy of Viber.app (your install is
#      never modified).
#   2. Launches that copy under lldb and captures the "PRAGMA hexkey=..." statements it
#      issues to unlock viber.db (a per-device key + a cipher-select string).
#   3. From inside the same process, opens its OWN connection to viber.db through Viber's
#      codec, applies the captured keys, and copies the message tables into a brand-new
#      PLAINTEXT database via `ATTACH ... KEY ''`.
#   4. Runs a join query over that plaintext DB to produce a CSV.
#
#   Keys and paths are discovered at RUNTIME — nothing is hardcoded to any one machine.
#
# NON-DESTRUCTIVE
#   Only ever READS your real viber.db. All writes go to a temp dir and to your chosen
#   output files. Your Viber data and app are left untouched.
#
# LEGAL / ETHICAL
#   Use ONLY on your own device, your own Viber account, and your own messages.
#
# USAGE
#   ./viber-export-macos.sh [-o OUTPUT_DIR] [-a /path/Viber.app] [-y]
#     -o OUTPUT_DIR   output location (default: ~/Desktop)
#     -a VIBER_APP    path to Viber.app (default: /Applications/Viber.app)
#     -y              don't prompt (assume "yes"); required for non-interactive runs
#   Env override: VIBER_DB=/path/to/viber.db  (skip auto-detection)
#
# License: MIT. No warranty. Contributions welcome.

set -euo pipefail
umask 077   # decrypted outputs contain private messages — never world-readable

# --------------------------------------------------------------------------- settings
VIBER_APP="/Applications/Viber.app"
OUT_DIR="${HOME}/Desktop"
ASSUME_YES=0
MAX_WAIT_SECS=360

while getopts ":o:a:yh" opt; do
  case "$opt" in
    o) OUT_DIR="$OPTARG" ;;
    a) VIBER_APP="$OPTARG" ;;
    y) ASSUME_YES=1 ;;
    h) sed -n '2,37p' "$0"; exit 0 ;;
    *) echo "Usage: $0 [-o OUTPUT_DIR] [-a VIBER_APP] [-y]"; exit 2 ;;
  esac
done

OUT_CSV="${OUT_DIR}/viber_export.csv"
OUT_PLAIN="${OUT_DIR}/viber_plain.db"

# --------------------------------------------------------------------------- ui helpers
_c() { [[ -t 1 ]] && printf '\033[%sm' "$1" || true; }
log()  { printf '%s[*]%s %s\n' "$(_c '1;34')" "$(_c 0)" "$*"; }
ok()   { printf '%s[+]%s %s\n' "$(_c '1;32')" "$(_c 0)" "$*"; }
warn() { printf '%s[!]%s %s\n' "$(_c '1;33')" "$(_c 0)" "$*"; }
hr()   { printf '%s\n' "----------------------------------------------------------------------"; }
# stop <why> then one or more "fix" lines
stop() {
  local why="$1"; shift
  echo; hr
  printf '%s[STOPPED]%s %s\n' "$(_c '1;31')" "$(_c 0)" "$why"
  if [[ $# -gt 0 ]]; then echo; echo "What to do:"; local l; for l in "$@"; do printf '   • %s\n' "$l"; done; fi
  hr
  exit 1
}
is_plaintext_sqlite() { # true if $1 begins with the SQLite magic (locale/binary safe)
  [ "$(head -c 15 "$1" 2>/dev/null)" = "SQLite format 3" ]
}
confirm() { # prompt unless -y; fail closed when non-interactive
  [[ $ASSUME_YES -eq 1 ]] && return 0
  if [[ ! -t 0 ]]; then return 1; fi
  local ans; read -r -p "    $1 [y/N] " ans || true
  [[ "$ans" == "y" || "$ans" == "Y" ]]
}

# CAVEAT / GRACEFUL FAILOVER
# This tool depends on Viber being built on Qt 6 and exposing a specific set of Qt SQL
# functions (whose C++ mangled names are used by the lldb injection). If a future Viber
# ships a different Qt major version or renames these, the injection cannot work. We
# verify all of that HERE — before copying/re-signing/launching anything — so the script
# stops with a clear, actionable message instead of failing deep inside lldb.
# NOTE: keep this list in sync with the SYMS dict in the embedded Python below.
QT_REQUIRED_SYMS_CORE="ZN7QString8fromUtf8E14QByteArrayView:QString::fromUtf8(QByteArrayView)"
QT_REQUIRED_SYMS_SQL="\
ZN9QSqlQuery4execERK7QString:QSqlQuery::exec(QString)
ZN10QSqlResult7prepareERK7QString:QSqlResult::prepare(QString)
ZN12QSqlDatabase11addDatabaseERK7QStringS2_:QSqlDatabase::addDatabase
ZN12QSqlDatabase15setDatabaseNameERK7QString:QSqlDatabase::setDatabaseName
ZN12QSqlDatabase4openEv:QSqlDatabase::open
ZN9QSqlQueryC1ERK12QSqlDatabase:QSqlQuery(QSqlDatabase)"

verify_qt_runtime() {
  local core sql qtver missing="" line sym human
  # `|| true`: a missing framework dir makes `find` exit non-zero, which under
  # `set -o pipefail`+`set -e` would abort here BEFORE the friendly message below.
  core="$(find "$VIBER_APP/Contents/Frameworks/QtCore.framework" -type f -name QtCore 2>/dev/null | head -1 || true)"
  sql="$(find "$VIBER_APP/Contents/Frameworks/QtSql.framework"  -type f -name QtSql  2>/dev/null | head -1 || true)"
  if [[ -z "$core" || -z "$sql" ]]; then
    stop "This Viber build does not bundle the expected Qt 6 QtCore/QtSql frameworks." \
      "The tool supports Viber Desktop built on Qt 6." \
      "Your Viber may be too old or too new — please report your version (Viber ▸ About)." \
      "Nothing was launched or modified."
  fi
  qtver="$(otool -L "$VIBER_APP/Contents/MacOS/Viber" 2>/dev/null | grep -m1 QtCore \
            | sed -nE 's/.*current version ([0-9][0-9.]*).*/\1/p' || true)"
  qtver="${qtver:-unknown}"

  # Capture nm output ONCE per framework and grep a here-string (not a pipe): under
  # `set -o pipefail`, `nm | grep -q` returns non-zero even on a match (grep closes the
  # pipe early → nm gets SIGPIPE), which would falsely flag present symbols as missing.
  local core_nm sql_nm
  core_nm="$(nm -gU "$core" 2>/dev/null || true)"
  sql_nm="$(nm -gU "$sql" 2>/dev/null || true)"

  sym="${QT_REQUIRED_SYMS_CORE%%:*}"; human="${QT_REQUIRED_SYMS_CORE#*:}"
  grep -qF "$sym" <<< "$core_nm" || missing="${missing}
   - ${human}  (QtCore)"
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    sym="${line%%:*}"; human="${line#*:}"
    grep -qF "$sym" <<< "$sql_nm" || missing="${missing}
   - ${human}  (QtSql)"
  done <<< "$QT_REQUIRED_SYMS_SQL"

  if [[ -n "$missing" ]]; then
    stop "Viber's Qt SQL interface does not match what this script expects (Qt build changed)." \
      "Detected Qt version: ${qtver}" \
      "Missing / renamed symbols:${missing}" \
      "This script targets Viber built on Qt 6 with standard symbol names." \
      "Fix: update the SYMS block in the script for your Viber's Qt build, or open an issue" \
      "     with your Viber version so it can be updated." \
      "Nothing was launched or modified."
  fi
  case "$qtver" in
    6.*)     ok "Qt runtime check passed (Qt ${qtver}); all required database symbols present." ;;
    unknown) warn "Could not read Viber's Qt version, but all required symbols are present — continuing." ;;
    *)       warn "Viber appears to use Qt ${qtver} (tool targets Qt 6), but required symbols are present — continuing." ;;
  esac
}

# =============================================================== PREFLIGHT / DEPENDENCIES
[[ "$(uname)" == "Darwin" ]] || stop "This tool only runs on macOS." \
  "Run it on the Mac that has Viber Desktop installed."

# Xcode command line tools provide lldb, codesign, python3, clang.
ensure_clt() {
  if xcode-select -p >/dev/null 2>&1 && command -v lldb >/dev/null 2>&1 \
     && command -v codesign >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
    return 0
  fi
  warn "Xcode Command Line Tools are required (they provide lldb, codesign, python3)."
  if confirm "Start Apple's installer now?"; then
    xcode-select --install 2>/dev/null || true
    stop "The Command Line Tools installer was launched." \
      "Finish the install dialog that appeared, then re-run this script." \
      "If no dialog appeared, run:  xcode-select --install"
  else
    stop "Missing Xcode Command Line Tools." \
      "Install them with:  xcode-select --install" \
      "Then re-run this script."
  fi
}
ensure_clt

SQLITE="$(command -v sqlite3 || true)"
[[ -n "$SQLITE" ]] || stop "sqlite3 was not found on this Mac." \
  "sqlite3 normally ships at /usr/bin/sqlite3. Reinstall Command Line Tools:" \
  "xcode-select --install"

# NB: because we launch an ad-hoc-signed copy with get-task-allow, lldb can debug it even
# with macOS "Developer Mode" off — so nothing to enable up front. If a launch is ever
# blocked, the failure handler below points the user at `sudo DevToolsSecurity -enable`.

[[ -d "$VIBER_APP" ]] || stop "Viber.app not found at: $VIBER_APP" \
  "Install Viber Desktop from https://www.viber.com/download/ and sign in," \
  "or point this script at it:  $0 -a /path/to/Viber.app"

# --------------------------------------------------------------- locate the database
VIBERPC="${HOME}/Library/Application Support/ViberPC"
if [[ -n "${VIBER_DB:-}" ]]; then
  [[ -f "$VIBER_DB" ]] || stop "VIBER_DB is set but not a file: $VIBER_DB" "Fix the path or unset VIBER_DB."
else
  [[ -d "$VIBERPC" ]] || stop "Viber data folder not found: $VIBERPC" \
    "Open Viber Desktop and sign in (scan the QR code) at least once, then re-run."
  _dbs=()
  while IFS= read -r line; do [[ -n "$line" ]] && _dbs+=("$line"); done < <(
    find "$VIBERPC" -maxdepth 2 -name viber.db 2>/dev/null -exec stat -f '%m %N' {} \; \
      | sort -rn | cut -d' ' -f2- )
  [[ ${#_dbs[@]} -gt 0 ]] || stop "No viber.db found under $VIBERPC" \
    "Open Viber Desktop, sign in, and let it finish syncing at least one chat, then re-run."
  if [[ ${#_dbs[@]} -gt 1 ]]; then
    warn "Multiple Viber accounts found; using the most recently used:"
    printf '        %s\n' "${_dbs[@]}"
    warn "Override with:  VIBER_DB=/path/to/viber.db $0"
  fi
  VIBER_DB="${_dbs[0]}"
fi
log "Database: $VIBER_DB"

# ------------------------------------------------------------------ prepare output dir
# (checked up front so a bad -o fails with a friendly message, not a raw cp abort)
mkdir -p "$OUT_DIR" || stop "Cannot create output dir: $OUT_DIR" "Choose a writable location with -o."
[[ -w "$OUT_DIR" ]] || stop "Output dir is not writable: $OUT_DIR" "Choose a writable location with -o."

# With "Desktop & Documents Folders" enabled in iCloud Drive, ~/Desktop and ~/Documents
# are uploaded to iCloud — which would send the decrypted chats off this Mac.
OUT_REAL="$(cd "$OUT_DIR" && pwd -P)"
ICLOUD_DRIVE="${HOME}/Library/Mobile Documents/com~apple~CloudDocs"
in_icloud=0
case "$OUT_REAL/" in "$ICLOUD_DRIVE"/*) in_icloud=1 ;; esac
for _d in Desktop Documents; do
  case "$OUT_REAL/" in "${HOME}/${_d}/"*) [[ -d "${ICLOUD_DRIVE}/${_d}" ]] && in_icloud=1 ;; esac
done
if [[ $in_icloud -eq 1 ]]; then
  warn "The output folder is synced to iCloud Drive: $OUT_DIR"
  warn "Your decrypted messages would be uploaded to iCloud."
  if ! confirm "Write them there anyway? (choose N and re-run with -o ~/viber-export to keep them local)"; then
    stop "Aborted so the decrypted chats are not uploaded to iCloud." \
      "Re-run with a local output folder, e.g.:  $0 -o ~/viber-export"
  fi
fi

# ------------------------------------------- shortcut: already plaintext? (older Viber)
if is_plaintext_sqlite "$VIBER_DB"; then
  ok "This viber.db is already unencrypted — skipping decryption."
  # VACUUM INTO (not cp) so rows still sitting in viber.db-wal are included consistently;
  # -readonly keeps the real viber.db untouched.
  rm -f "$OUT_PLAIN"
  _q=${OUT_PLAIN//\'/\'\'}
  "$SQLITE" -readonly "$VIBER_DB" "VACUUM INTO '${_q}';" \
    || stop "Failed to write $OUT_PLAIN" "Choose a writable location with -o."
  chmod 600 "$OUT_PLAIN" 2>/dev/null || true
  PLAIN_FOR_CSV="$OUT_PLAIN"
  SKIP_DECRYPT=1
else
  SKIP_DECRYPT=0
fi

# ============================================================ DECRYPTION (if needed)
if [[ "$SKIP_DECRYPT" -eq 0 ]]; then

  # Fail fast if this Viber's Qt build isn't what the injection expects.
  verify_qt_runtime

  # Guard: a second instance of the same account can disrupt your linked desktop.
  if pgrep -x Viber >/dev/null 2>&1; then
    warn "Viber is currently running."
    if ! confirm "Quit it yourself now and then continue? (choose N to abort)"; then
      stop "Viber is running; aborting to avoid disrupting your linked desktop." \
        "Quit Viber (Cmd-Q), then re-run this script." \
        "Or re-run with -y to proceed anyway (reads are safe, but the running app may re-sync)."
    fi
    if [[ $ASSUME_YES -eq 0 ]]; then
      log "Waiting for Viber to quit (Cmd-Q it now)..."
      _w=0
      while pgrep -x Viber >/dev/null 2>&1 && [[ $_w -lt 60 ]]; do sleep 1; _w=$((_w + 1)); done
      pgrep -x Viber >/dev/null 2>&1 && stop "Viber is still running after 60s." \
        "Quit Viber (Cmd-Q), then re-run this script." \
        "Or re-run with -y to proceed anyway."
      ok "Viber has quit."
    fi
  fi

  WORK="$(mktemp -d "${TMPDIR:-/tmp}/viberexp.XXXXXX")" || stop "Could not create a temp working directory." "Check disk space and permissions on \$TMPDIR."
  DBG_APP="${WORK}/ViberDbg.app"
  INJECT_PY="${WORK}/inject.py"
  MARKER="${WORK}/done.marker"
  RUN_LOG="${WORK}/lldb.log"
  WORK_PLAIN="${WORK}/plain.db"
  # Terminate the debuggable Viber copy and sweep any orphaned helper processes
  # (Viber is multi-process). Loop a few times to catch stragglers/relaunches.
  stop_dbg() {
    _i=0
    while pgrep -f "$DBG_APP" >/dev/null 2>&1 && [ "$_i" -lt 5 ]; do
      pkill -KILL -f "$DBG_APP" 2>/dev/null || true
      sleep 1; _i=$((_i+1))
    done
  }
  LLDB_PID=""
  cleanup() {
    [[ -n "$LLDB_PID" ]] && kill -KILL "$LLDB_PID" 2>/dev/null || true
    stop_dbg; rm -rf "$WORK" 2>/dev/null || true
  }
  # A bare INT/TERM trap would run cleanup and then RESUME the script (with $WORK gone);
  # exit explicitly so Ctrl-C actually stops it.
  trap cleanup EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM

  # On failure we point users at a debug log; copy it OUT of the temp dir (which cleanup
  # deletes) with any hexkey values redacted, so no key material is ever persisted.
  DEBUG_LOG="${OUT_DIR}/viber-export-debug.log"
  save_debug_log() {
    [ -f "$RUN_LOG" ] || return 0
    sed -E "s/hexkey[[:space:]]*=[[:space:]]*'[^']*'/hexkey='<redacted>'/g" "$RUN_LOG" \
      > "$DEBUG_LOG" 2>/dev/null && chmod 600 "$DEBUG_LOG" 2>/dev/null || true
  }

  # Rough free-space check (need room for the ~400 MB app copy).
  avail_kb="$(df -k "$WORK" | awk 'NR==2{print $4}')"
  if [[ -n "$avail_kb" && "$avail_kb" -lt 600000 ]]; then
    stop "Not enough free disk space in ${TMPDIR:-/tmp} (need ~600 MB for a temporary Viber copy)." \
      "Free up space, or set TMPDIR to a volume with room:  TMPDIR=/Volumes/Big $0"
  fi

  log "Making a temporary debuggable copy of Viber (your install is untouched)..."
  # On APFS, -c makes an instant copy-on-write clone (no extra disk used); fall back to a
  # normal copy when cloning isn't possible (e.g. TMPDIR on another volume).
  if ! cp -Rc "$VIBER_APP" "$DBG_APP" 2>/dev/null; then
    rm -rf "$DBG_APP"
    cp -R "$VIBER_APP" "$DBG_APP" || stop "Failed to copy Viber.app into $WORK." "Check disk space and permissions."
  fi
  cat > "${WORK}/ent.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>com.apple.security.get-task-allow</key><true/>
</dict></plist>
PLIST
  log "Ad-hoc re-signing the copy for debugging..."
  # codesign refuses a bundle with anything but Contents/ in its root ("unsealed contents
  # present in the bundle root") — some Viber installs ship e.g. a manifest.md5 there.
  find "$DBG_APP" -mindepth 1 -maxdepth 1 ! -name Contents -exec rm -rf {} +
  # Finder info / quarantine xattrs make codesign fail with "resource fork ... detritus".
  xattr -cr "$DBG_APP" 2>/dev/null || true
  codesign --remove-signature "$DBG_APP" 2>/dev/null || true
  if ! cs_err="$(codesign --force --deep --sign - --entitlements "${WORK}/ent.plist" "$DBG_APP" 2>&1)"; then
    stop "Re-signing the Viber copy failed (codesign error)." \
      "codesign said: $(tail -n 3 <<< "$cs_err" | tr '\n' ' ')" \
      "Ensure Command Line Tools are installed:  xcode-select --install" \
      "Then re-run. If it persists, your Viber.app may be damaged — reinstall Viber."
  fi

  # ---- lldb injection script (architecture-aware; captures keys; exports plaintext) ---
  cat > "$INJECT_PY" <<'PYEOF'
import lldb, os, re
VIBER_DB = os.environ["VIBER_DB"]
OUT_DB   = os.environ["OUT_DB"]
MARKER   = os.environ["MARKER"]
ST = {"keys": [], "since": 0, "done": False, "argreg": None}

# Qt6 C++ ABI mangled symbol names (stable across machines for a given Qt6 build).
SYMS = {
    "mk":   "_ZN7QString8fromUtf8E14QByteArrayView",
    "ex":   "_ZN9QSqlQuery4execERK7QString",
    "add":  "_ZN12QSqlDatabase11addDatabaseERK7QStringS2_",
    "setn": "_ZN12QSqlDatabase15setDatabaseNameERK7QString",
    "open": "_ZN12QSqlDatabase4openEv",
    "qqc":  "_ZN9QSqlQueryC1ERK12QSqlDatabase",
}

def _mark(s):
    try:
        with open(MARKER, "w") as f:
            f.write(s); f.flush(); os.fsync(f.fileno())
    except Exception: pass

def _addr(t, name):
    scl = t.FindSymbols(name)
    for i in range(scl.GetSize()):
        a = scl.GetContextAtIndex(i).symbol.GetStartAddress().GetLoadAddress(t)
        if a != lldb.LLDB_INVALID_ADDRESS:
            return a
    return None

def _argreg(frame):
    # 2nd integer argument register: x1 on arm64, rsi on x86_64 (Intel / Rosetta).
    if ST["argreg"] is None:
        tri = (frame.thread.process.GetTarget().GetTriple() or "").lower()
        ST["argreg"] = "x1" if (tri.startswith("arm64") or tri.startswith("aarch64")) else "rsi"
    return ST["argreg"]

def _read_qstring(frame):
    err = lldb.SBError(); proc = frame.thread.process
    a = frame.FindRegister(_argreg(frame)).GetValueAsUnsigned()   # &QString
    if not a:
        return None
    ptr  = proc.ReadPointerFromMemory(a + 8, err)                 # {Data*; char16_t* ptr; size}
    size = proc.ReadUnsignedFromMemory(a + 16, 8, err)
    if err.Fail() or not (0 < size < 1_000_000):
        return None
    raw = proc.ReadMemory(ptr, int(size) * 2, err)
    if err.Fail():
        return None
    try:    return raw.decode("utf-16-le", "replace")
    except Exception: return None

def _export(frame, keys):
    t = lldb.debugger.GetSelectedTarget()
    S = {k: _addr(t, v) for k, v in SYMS.items()}
    missing = [SYMS[k] for k, v in S.items() if v is None]
    if missing:
        _mark("ERR:symbols:" + ",".join(missing)); return
    def M(s):
        e = s.replace("\\", "\\\\").replace('"', '\\"')
        return 'mk(%dLL,"%s")' % (len(s.encode()), e)
    keylines = "\n".join(
        'QS k%d=%s; ex(&q,&k%d);' % (i, M("PRAGMA hexkey='%s'" % k), i)
        for i, k in enumerate(keys))
    expr = '''
    struct QS{void*a;void*b;long long c;};
    struct DB{void*d;void*p1;void*p2;};   /* >16 bytes -> memory/sret on arm64 & x86_64 */
    struct QQ{void*d;};
    QS(*mk)(long long,const char*)=(QS(*)(long long,const char*))%(mk)dULL;
    bool(*ex)(void*,QS*)=(bool(*)(void*,QS*))%(ex)dULL;
    DB(*add)(const void*,const void*)=(DB(*)(const void*,const void*))%(add)dULL;
    void(*setn)(void*,const void*)=(void(*)(void*,const void*))%(setn)dULL;
    bool(*opn)(void*)=(bool(*)(void*))%(open)dULL;
    void(*qqc)(void*,const void*)=(void(*)(void*,const void*))%(qqc)dULL;
    QS tp=%(TP)s; QS cn=%(CN)s; DB db=add(&tp,&cn);
    QS pth=%(PTH)s; setn(&db,&pth); bool o=opn(&db);
    QQ q; qqc(&q,&db);
    %(KEYS)s
    QS pb=%(PROBE)s; bool rd=ex(&q,&pb);
    QS at=%(ATT)s; bool ra=ex(&q,&at);
    QS m=%(CPM)s; bool rm=ex(&q,&m);
    QS e=%(CPE)s; bool re=ex(&q,&e);
    QS c=%(CPC)s; bool rc=ex(&q,&c);
    QS dd=%(DET)s; ex(&q,&dd);
    (int)((o?1:0)+(rd?2:0)+(ra?4:0)+(rm?8:0)+(re?16:0)+(rc?32:0));''' % {
        "mk":S["mk"],"ex":S["ex"],"add":S["add"],"setn":S["setn"],"open":S["open"],"qqc":S["qqc"],
        "TP":M("QSQLITE"),"CN":M("viber_export_conn"),"PTH":M(VIBER_DB),"KEYS":keylines,
        "PROBE":M("SELECT count(*) FROM sqlite_master"),
        # escape single quotes for the SQL string literal (defense-in-depth; OUT_DB is a
        # temp mktemp path today, but never build SQL without quoting the value).
        "ATT":M("ATTACH DATABASE '%s' AS plain KEY ''" % OUT_DB.replace("'", "''")),
        "CPM":M("CREATE TABLE plain.Messages AS SELECT * FROM main.Messages"),
        "CPE":M("CREATE TABLE plain.Events   AS SELECT * FROM main.Events"),
        "CPC":M("CREATE TABLE plain.Contact  AS SELECT * FROM main.Contact"),
        "DET":M("DETACH DATABASE plain"),
    }
    o = lldb.SBExpressionOptions()
    o.SetIgnoreBreakpoints(True); o.SetUnwindOnError(True)
    o.SetTryAllThreads(True); o.SetTimeoutInMicroSeconds(300_000_000)
    o.SetLanguage(lldb.eLanguageTypeC_plus_plus)
    v = frame.EvaluateExpression(expr, o)
    if not v.GetError().Success():
        # A compile-stage error can quote the source line (which contains the key), so
        # redact any hexkey values before persisting/printing the diagnostic.
        raw = v.GetError().GetCString() or "unknown"
        safe = re.sub(r"hexkey\s*=\s*'[^']*'", "hexkey='<redacted>'", raw)
        _mark("ERR:expr:" + safe[:300]); return
    _mark("OK:%d:keys=%d" % (v.GetValueAsSigned(), len(keys)))

def _trigger(frame):
    if ST["done"] or not ST["keys"]:
        return
    ST["done"] = True
    _export(frame, ST["keys"])
    # Our export used a separate read connection and DETACHed it; terminate the debuggee
    # under lldb (clean, no orphaned/relaunched instance). viber.db is WAL-journaled, so
    # SQLite recovers cleanly even from a hard stop.
    try: frame.thread.process.Kill()
    except Exception: pass
    os._exit(0)

def on_sql(frame, bp_loc, extra, internal_dict):
    if ST["done"]:
        return False
    sql = _read_qstring(frame)
    if not sql:
        return False
    if "hexkey" in sql.lower():
        m = re.search(r"hexkey\s*=\s*'([^']*)'", sql, re.I)
        if m and m.group(1) not in ST["keys"]:
            ST["keys"].append(m.group(1)); ST["since"] = 0
        # Two keys is the known pattern; export as soon as we have them.
        if len(ST["keys"]) >= 2:
            _trigger(frame)
        return False
    # Fallback for Viber builds that issue a single hexkey: once keys have been seen
    # and issuance appears finished (a real content query, or enough statements pass).
    if ST["keys"]:
        ST["since"] += 1
        if re.search(r"\bfrom\b\s+(messages|events|contact|conversation)", sql, re.I) or ST["since"] > 40:
            _trigger(frame)
    return False
PYEOF

  # ------------------------------------------------------------------------- run lldb
  log "Launching the debuggable Viber under lldb to capture the key (a Viber window will appear)..."
  rm -f "$WORK_PLAIN" "$MARKER"
  VIBER_DB="$VIBER_DB" OUT_DB="$WORK_PLAIN" MARKER="$MARKER" \
    nohup lldb -b \
      -o "command script import $INJECT_PY" \
      -o "breakpoint set -n _ZN9QSqlQuery4execERK7QString" \
      -o "breakpoint command add -s python -F inject.on_sql 1" \
      -o "breakpoint set -n _ZN10QSqlResult7prepareERK7QString" \
      -o "breakpoint command add -s python -F inject.on_sql 2" \
      -o "run" \
      "${DBG_APP}/Contents/MacOS/Viber" > "$RUN_LOG" 2>&1 &
  LLDB_PID=$!

  # Detect an immediate lldb/launch failure vs. genuine "waiting for the app".
  log "Waiting for the key and export (up to ${MAX_WAIT_SECS}s)..."
  waited=0
  while [[ ! -f "$MARKER" ]] && [[ $waited -lt $MAX_WAIT_SECS ]]; do
    sleep 2; waited=$((waited + 2))
    kill -0 "$LLDB_PID" 2>/dev/null || break
  done
  stop_dbg

  # -------------------------------------------------------- interpret what happened
  if [[ ! -f "$MARKER" ]]; then
    # No key captured. Figure out the most likely reason from the lldb log.
    save_debug_log
    if grep -qiE 'Developer Tools|debugserver|not permitted|Operation not permitted|EPERM' "$RUN_LOG"; then
      stop "lldb was not allowed to launch/debug Viber on this Mac." \
        "Enable debugging:  sudo DevToolsSecurity -enable" \
        "Then re-run this script." \
        "Redacted details saved to: $DEBUG_LOG"
    elif grep -qiE 'Unable to resolve breakpoint|no locations' "$RUN_LOG" && ! grep -qi 'captured' "$RUN_LOG"; then
      stop "The Qt database symbols were not found (Viber's Qt version differs from what this script expects)." \
        "This script targets Viber built on Qt 6. Check for an updated version of the script," \
        "or open an issue with your Viber version (Viber ▸ About)." \
        "Redacted details saved to: $DEBUG_LOG"
    else
      stop "Timed out before Viber unlocked its database (no key was captured)." \
        "Make sure Viber is fully SIGNED IN (scan the QR code) and can sync — it must open" \
        "viber.db during launch for the key to appear." \
        "Check your internet connection and try again." \
        "If a Viber login window is waiting for you, complete it and re-run." \
        "Redacted details saved to: $DEBUG_LOG"
    fi
  fi

  status="$(cat "$MARKER")"
  case "$status" in
    ERR:symbols:*)
      stop "Could not find Viber's Qt SQL functions (Qt version mismatch)." \
        "This build of Viber differs from what the script expects (Qt6 symbol names changed)." \
        "Missing: ${status#ERR:symbols:}" \
        "Please report your Viber version so the script can be updated." ;;
    ERR:expr:*)
      stop "The in-process export call failed." \
        "Reason: ${status#ERR:expr:}" \
        "Re-run once more; if it persists, report it with your Viber + macOS versions." ;;
    OK:*)
      bm="${status#OK:}"; bm="${bm%%:*}"
      if (( (bm & 2) == 0 )); then
        stop "Captured the key(s) but could NOT decrypt viber.db with them." \
          "Viber may use a different unlock sequence in your version." \
          "Please report your Viber version (Viber ▸ About) so this can be fixed." \
          "Diagnostic bitmask: $bm"
      fi
      if (( (bm & 8) == 0 )); then
        warn "The 'Messages' table wasn't copied (bitmask $bm) — schema may differ in your Viber version."
      fi
      ;;
    *)
      save_debug_log
      stop "Unexpected internal status: $status" "Please report this along with: $DEBUG_LOG" ;;
  esac

  # ------------------------------------------------- validate the plaintext output
  [[ -f "$WORK_PLAIN" ]] || stop "Decryption reported success but no output file was produced." \
    "Re-run once; if it persists, report with your Viber + macOS versions."
  is_plaintext_sqlite "$WORK_PLAIN" || \
    stop "The produced file is not a valid plaintext SQLite database." \
      "Re-run once; if it persists, report with your Viber + macOS versions."

  cp "$WORK_PLAIN" "$OUT_PLAIN" || stop "Failed to write $OUT_PLAIN" "Choose a writable location with -o."
  chmod 600 "$OUT_PLAIN" 2>/dev/null || true
  PLAIN_FOR_CSV="$OUT_PLAIN"
  ok "Decrypted plaintext database written: $OUT_PLAIN"
fi

# =================================================================== CSV GENERATION
if ! "$SQLITE" "$PLAIN_FOR_CSV" "SELECT 1 FROM Messages LIMIT 1;" >/dev/null 2>&1; then
  stop "No 'Messages' table in the decrypted database — cannot build the message CSV." \
    "Your Viber schema may differ. The plaintext DB is at: $PLAIN_FOR_CSV" \
    "Inspect it with:  sqlite3 \"$PLAIN_FOR_CSV\" .tables"
fi

MSG_ROWS="$("$SQLITE" "$PLAIN_FOR_CSV" "SELECT count(*) FROM Messages;" 2>/dev/null || echo '?')"
log "Messages in database: $MSG_ROWS — writing CSV..."

# UTF-8 BOM first: without it Excel/Numbers show non-Latin text (Cyrillic, Greek, emoji…)
# as mojibake.
printf '\xEF\xBB\xBF' > "$OUT_CSV"
if ! csv_err="$("$SQLITE" -header -csv "$PLAIN_FOR_CSV" 2>&1 >>"$OUT_CSV" "
SELECT
  datetime(e.TimeStamp/1000,'unixepoch','localtime')                              AS DateTime,
  e.ChatID                                                                        AS ChatID,
  COALESCE(NULLIF(c.Name,''), NULLIF(c.ClientName,''), NULLIF(c.Number,''),
           'ContactID:'||e.ContactID)                                             AS Contact,
  CASE e.Direction WHEN 0 THEN 'received' ELSE 'sent' END                         AS Direction,
  m.Type                                                                          AS MsgType,
  m.Body                                                                          AS Message
FROM Events e
JOIN Messages m ON m.EventID = e.EventID
LEFT JOIN Contact c ON c.ContactID = e.ContactID
WHERE m.Body IS NOT NULL AND m.Body <> ''
ORDER BY e.TimeStamp ASC;")"; then
  stop "Failed while writing the CSV." \
    "sqlite3 said: ${csv_err:-unknown error}" \
    "The plaintext DB is available at: $PLAIN_FOR_CSV — you can query it directly." \
    "Report the error with your Viber + macOS versions."
fi
chmod 600 "$OUT_CSV" 2>/dev/null || true

echo; hr
ok "Done."
echo "    CSV : $OUT_CSV"
echo "    DB  : $OUT_PLAIN   (plaintext SQLite — query it directly if you like)"
echo
echo "Tip: numeric 'Message' values with MsgType != 0 are media/stickers (token IDs), not text."
hr
