#!/bin/bash
# Two-device sync test over a real tailnet path.
#
#   Debug IMM (demo vault, sync on) ── agent listens on 100.x:47380
#        ▲
#        │ ssh -N -L 47381:<mac tailnet ip>:47380 <ssh host>     (the ssh host on your tailnet dials the Mac's tailnet address)
#        │
#   imm-sync-peer (headless second device, own encrypted vault) dials 127.0.0.1:47381
#
# What it does: builds the signed Debug app and the peer tool, starts the app on a fresh demo vault with sync on, pairs the peer by
# the printed code (the code is auto-confirmed: test only), then times
#   1. peer -> Mac, one shot (dial + handshake + push)           peer commit -> remote op applied in the app
#   2. peer -> Mac, live (peer session already open)               peer commit -> remote op applied in the app
#   3. Mac -> peer, live relay                                     app commit  -> op applied in the peer
#   4. app quit: peer edits land in the agent's mailbox; relaunch applies them
#   5. Mac edits published to the outbox, app quit: peer fetches them from the agent
# and checks that the agent listens on the tailnet address only (lsof; nc from the LAN address is refused).
# Cleanup: sync off (unregisters the agent), kills only the PIDs this script started, closes the ssh forward, deletes its temp files.
#
# Usage: Tools/sync-tailnet-test.sh --ssh-host HOST [--rounds N] [--skip-build] [--local-port PORT]
#        (or set IMM_SYNC_TEST_SSH_HOST). HOST is any machine on your tailnet you can ssh into; nothing is installed there.
# Output: a summary table with min / median / p95 / max in milliseconds, then PASS or FAIL. Exit status 0 only when every check passed.
# The app's stdout (sandboxed app: its container cannot be read from outside) is the channel: pairing code, remote ops, local edits.

set -u -o pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
SSH_HOST="${IMM_SYNC_TEST_SSH_HOST:-}"
LOCAL_PORT=47381
AGENT_PORT=47380
ROUNDS=8
SKIP_BUILD=0
PASSWORD=peer-test-pw
TX=REWE

while [ $# -gt 0 ]; do
  case "$1" in
    --rounds) ROUNDS="$2"; shift 2 ;;
    --skip-build) SKIP_BUILD=1; shift ;;
    --ssh-host) SSH_HOST="$2"; shift 2 ;;
    --local-port) LOCAL_PORT="$2"; shift 2 ;;
    *) echo "unknown option $1" >&2; exit 2 ;;
  esac
done
[ -n "$SSH_HOST" ] || { echo "Set --ssh-host HOST (a machine on your tailnet you can ssh into)." >&2; exit 2; }

WORK="$(mktemp -d /tmp/imm-sync-tailnet.XXXXXX)"
APP_LOG="$WORK/app.log"
WATCH_LOG="$WORK/watch.log"
PEER_DIR="$WORK/Peer.imm"
APP_PID=""
SSH_PID=""
WATCH_PID=""
FIFO_OPEN=0
FAILURES=0
: > "$APP_LOG"

say() { printf '%s\n' "$*"; }
note() { printf '  %s\n' "$*"; }
check() { # check <description> <exit status>
  if [ "$2" -eq 0 ]; then say "  ok   $1"; else say "  FAIL $1"; FAILURES=$((FAILURES + 1)); fi
}
now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
die() { say "ABORT: $*"; say "--- app log tail ---"; tail -n 25 "$APP_LOG" 2>/dev/null; FAILURES=$((FAILURES + 1)); exit 1; }

count() { grep -cE "$2" "$1" 2>/dev/null || true; }
last_ms() { grep -E "$2" "$1" | tail -n 1 | awk '{print $1}'; }
# wait_for <file> <pattern> <previous count> <timeout seconds>
wait_for() {
  local file="$1" pattern="$2" before="$3" limit="$4" i=0
  while [ "$i" -lt $((limit * 20)) ]; do
    [ "$(count "$file" "$pattern")" -gt "$before" ] && return 0
    sleep 0.05
    i=$((i + 1))
  done
  return 1
}

cleanup() {
  local status=$?
  set +e
  say ""
  say "== cleanup"
  if [ -n "$APP_PID" ] && kill -0 "$APP_PID" 2>/dev/null; then
    if [ "$FIFO_OPEN" -eq 1 ]; then
      echo '{"sync":"off"}' >&3 2>/dev/null
      for _ in $(seq 1 60); do grep -q "sync off requested" "$APP_LOG" && break; sleep 0.1; done
      sleep 1.5
    fi
    kill "$APP_PID" 2>/dev/null
    wait "$APP_PID" 2>/dev/null
    note "app $APP_PID stopped"
  fi
  if [ -n "$WATCH_PID" ] && kill -0 "$WATCH_PID" 2>/dev/null; then kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; fi
  if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then kill "$SSH_PID" 2>/dev/null; wait "$SSH_PID" 2>/dev/null; note "ssh forward $SSH_PID closed"; fi
  exec 3>&- 2>/dev/null
  if launchctl print "gui/$(id -u)/dev.gasi.imm.sync-agent" >/dev/null 2>&1; then
    # Sync off unregisters it; if the app died before that, remove the job ourselves.
    launchctl bootout "gui/$(id -u)/dev.gasi.imm.sync-agent" 2>/dev/null
    note "agent job was still loaded: removed with launchctl bootout"
  fi
  sleep 0.5
  say "  launchd job:  $(launchctl print "gui/$(id -u)/dev.gasi.imm.sync-agent" >/dev/null 2>&1 && echo STILL LOADED || echo gone)"
  say "  listeners on :$AGENT_PORT:  $(lsof -nP -iTCP:$AGENT_PORT -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  say "  listeners on :$LOCAL_PORT:  $(lsof -nP -iTCP:$LOCAL_PORT -sTCP:LISTEN 2>/dev/null | tail -n +2 | wc -l | tr -d ' ')"
  say "  agent processes:  $(pgrep -f 'IMM Sync Agent' | wc -l | tr -d ' ')"
  say "  tailscale serve:  $(/Applications/Tailscale.app/Contents/MacOS/Tailscale serve status 2>&1 | head -n 1)"
  rm -rf "$WORK"
  if [ "$FAILURES" -eq 0 ] && [ "$status" -eq 0 ]; then say "RESULT: PASS"; else say "RESULT: FAIL ($FAILURES failed checks)"; [ "$status" -eq 0 ] && status=1; fi
  exit "$status"
}
trap cleanup EXIT INT TERM

# ---------------------------------------------------------------------------------------------------------------- environment
say "== environment"
TAILNET_IP="$(ifconfig | awk '/inet 100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\./ {print $2; exit}')"
LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
[ -n "$TAILNET_IP" ] || die "this Mac has no tailnet address (is Tailscale running?)"
note "Mac tailnet address $TAILNET_IP, LAN address ${LAN_IP:-none}, forward via $SSH_HOST on 127.0.0.1:$LOCAL_PORT"
ssh -o BatchMode=yes -o ConnectTimeout=8 "$SSH_HOST" true || die "cannot ssh to $SSH_HOST"
if lsof -nP -iTCP:"$LOCAL_PORT" -sTCP:LISTEN >/dev/null 2>&1; then die "local port $LOCAL_PORT is already in use"; fi
if lsof -nP -iTCP:"$AGENT_PORT" -sTCP:LISTEN >/dev/null 2>&1; then die "something already listens on :$AGENT_PORT (stop it first)"; fi

# ---------------------------------------------------------------------------------------------------------------- build
if [ "$SKIP_BUILD" -eq 0 ]; then
  say "== build (Debug app, peer tool)"
  (cd "$ROOT" && /opt/homebrew/bin/xcodegen generate >/dev/null) || die "xcodegen failed"
  (cd "$ROOT" && xcodebuild -project IMM.xcodeproj -scheme IMM -configuration Debug -destination 'platform=macOS' \
     -allowProvisioningUpdates -allowProvisioningDeviceRegistration -derivedDataPath build/dd build >"$WORK/xcodebuild.log" 2>&1) \
     || { tail -n 30 "$WORK/xcodebuild.log"; die "xcodebuild failed"; }
  (cd "$ROOT" && swift build --package-path Packages/IMMKit --product imm-sync-peer >"$WORK/swiftbuild.log" 2>&1) \
     || { tail -n 30 "$WORK/swiftbuild.log"; die "swift build failed"; }
fi
APP="$ROOT/build/dd/Build/Products/Debug/IMM.app"
PEER="$(cd "$ROOT" && swift build --package-path Packages/IMMKit --show-bin-path)/imm-sync-peer"
[ -x "$APP/Contents/MacOS/IMM" ] || die "no Debug app at $APP"
[ -x "$PEER" ] || die "no peer tool at $PEER"
codesign --verify --strict "$APP" 2>/dev/null; check "Debug app is signed" $?
codesign --verify --strict "$APP/Contents/Library/LoginItems/IMM Sync Agent.app" 2>/dev/null; check "embedded agent is signed" $?

# ---------------------------------------------------------------------------------------------------------------- app
say "== start the app (fresh demo vault, sync on)"
mkfifo "$WORK/stdin"
exec 3<>"$WORK/stdin"
FIFO_OPEN=1
launch_app() { # launch_app [extra args...]
  "$APP/Contents/MacOS/IMM" -IMMDemoVault YES "$@" -IMMSyncEnable YES -IMMSyncPrintPairingCode YES -IMMSyncAutoConfirm YES \
     -IMMSyncDebugEdit YES -IMMSyncDumpOnChange YES <&3 >>"$APP_LOG" 2>&1 &
  APP_PID=$!
}
START_MS="$(now_ms)"
launch_app -IMMDemoVaultFresh YES
note "app pid $APP_PID"
wait_for "$APP_LOG" '^[0-9]+ demo-ready' 0 90 || die "the demo vault was not ready within 90 s"
note "demo ledger imported $(( $(last_ms "$APP_LOG" 'demo-ready') - START_MS )) ms after launch"
wait_for "$APP_LOG" '^[0-9]+ pairing code=' 0 90 || die "the app did not print a pairing code (needs approval in System Settings > Login Items? no tailnet?)"
LISTEN_MS="$(last_ms "$APP_LOG" 'pairing code=')"
note "pairing offer printed $((LISTEN_MS - START_MS)) ms after launch"
PAIR_LINE="$(grep -E '^[0-9]+ pairing code=' "$APP_LOG" | tail -n 1)"
CODE="$(echo "$PAIR_LINE" | sed -E 's/.*code=([A-Z2-7-]+).*/\1/')"
AGENT_KEY="$(echo "$PAIR_LINE" | sed -E 's/.*agent=([0-9a-f]+).*/\1/')"
note "code $CODE, agent key ${AGENT_KEY:0:16}…"

say "== network checks"
LSOF="$(lsof -nP -iTCP:$AGENT_PORT -sTCP:LISTEN 2>/dev/null | tail -n +2)"
note "lsof: ${LSOF:-<nothing visible>}"
[ -n "$LSOF" ]; check "the agent listens on :$AGENT_PORT" $?
echo "$LSOF" | grep -q "$TAILNET_IP:$AGENT_PORT"; check "listener is bound to the tailnet address $TAILNET_IP" $?
echo "$LSOF" | grep -qE '\*:'"$AGENT_PORT"'|127\.0\.0\.1:'"$AGENT_PORT"'|192\.168\.|\[::'; test $? -ne 0; check "no wildcard, loopback or LAN listener" $?
if [ -n "$LAN_IP" ]; then nc -z -w 3 "$LAN_IP" "$AGENT_PORT" 2>/dev/null; test $? -ne 0; check "nc to the LAN address $LAN_IP:$AGENT_PORT is refused" $?; fi
nc -z -w 3 127.0.0.1 "$AGENT_PORT" 2>/dev/null; test $? -ne 0; check "nc to loopback :$AGENT_PORT is refused" $?
ssh -o BatchMode=yes "$SSH_HOST" "nc -z -w 5 $TAILNET_IP $AGENT_PORT" 2>/dev/null; check "$SSH_HOST reaches $TAILNET_IP:$AGENT_PORT over the tailnet" $?

# ---------------------------------------------------------------------------------------------------------------- forward + pair
say "== forward and pair"
ssh -N -o BatchMode=yes -o ExitOnForwardFailure=yes -o ServerAliveInterval=15 -L "$LOCAL_PORT:$TAILNET_IP:$AGENT_PORT" "$SSH_HOST" &
SSH_PID=$!
for _ in $(seq 1 100); do nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null && break; sleep 0.1; done
nc -z 127.0.0.1 "$LOCAL_PORT" 2>/dev/null || die "ssh forward did not come up"
note "ssh forward pid $SSH_PID"

"$PEER" init --vault "$PEER_DIR" --password "$PASSWORD" --name "Test peer (via $SSH_HOST)" >/dev/null || die "peer init failed"
PAIR_T0="$(now_ms)"
"$PEER" pair --vault "$PEER_DIR" --password "$PASSWORD" --host 127.0.0.1 --port "$LOCAL_PORT" --code "$CODE" --agent-key "$AGENT_KEY" \
  >"$WORK/pair.log" 2>&1
PAIR_STATUS=$?
PAIR_T1="$(now_ms)"
cat "$WORK/pair.log" | sed 's/^/    peer: /'
check "pairing completed (QR/code, 6-digit confirmation, grant, snapshot)" $PAIR_STATUS
[ $PAIR_STATUS -eq 0 ] || die "pairing failed"
note "pairing + snapshot of the demo ledger took $((PAIR_T1 - PAIR_T0)) ms"

dump() { "$PEER" dump --vault "$PEER_DIR" --password "$PASSWORD" --tx "$TX" "$@"; }
NET="$(dump | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["netWorthCents"], d["uncategorised"])')"
note "peer ledger after bootstrap: net worth ${NET% *} cents, ${NET#* } uncategorised"
[ "${NET% *}" = "6305854" ]; check "peer net worth equals the Mac's demo ledger (63.058,54 EUR)" $?
[ "${NET#* }" = "6" ]; check "peer uncategorised count equals the Mac's (6)" $?

latency_file() { echo "$WORK/lat-$1.txt"; }
record() { echo "$2" >> "$(latency_file "$1")"; }
CATS=(Groceries Other)

# ---------------------------------------------------------------------------------------------------------------- 1. peer -> Mac, one shot
say "== 1. peer -> Mac, one shot per edit (dial, Noise IK, push, ack)  x$ROUNDS"
for i in $(seq 1 "$ROUNDS"); do
  before="$(count "$APP_LOG" 'remote-op ledger_transaction .* category_id')"
  out="$("$PEER" set-category --vault "$PEER_DIR" --password "$PASSWORD" --tx "$TX" --category "${CATS[$((i % 2))]}" --host 127.0.0.1 --port "$LOCAL_PORT")"
  committed="$(echo "$out" | awk '/committed/ {print $1; exit}')"
  if wait_for "$APP_LOG" 'remote-op ledger_transaction .* category_id' "$before" 10; then
    applied="$(last_ms "$APP_LOG" 'remote-op ledger_transaction .* category_id')"
    record one-shot $((applied - committed))
  else
    check "round $i: the app applied the peer's category edit" 1
  fi
done

# ---------------------------------------------------------------------------------------------------------------- 2/3. live
say "== 2. peer -> Mac with the peer session open, 3. Mac -> peer live relay"
"$PEER" sync --vault "$PEER_DIR" --password "$PASSWORD" --host 127.0.0.1 --port "$LOCAL_PORT" --watch 400 >"$WATCH_LOG" 2>&1 &
WATCH_PID=$!
wait_for "$WATCH_LOG" 'connected' 0 10 || die "the watching peer did not connect"
sleep 1.5
for i in $(seq 1 "$ROUNDS"); do
  before="$(count "$APP_LOG" 'remote-op ledger_transaction .* category_id')"
  out="$("$PEER" set-category --vault "$PEER_DIR" --password "$PASSWORD" --tx "$TX" --category "${CATS[$((i % 2))]}")"
  committed="$(echo "$out" | awk '/committed/ {print $1; exit}')"
  if wait_for "$APP_LOG" 'remote-op ledger_transaction .* category_id' "$before" 10; then
    applied="$(last_ms "$APP_LOG" 'remote-op ledger_transaction .* category_id')"
    record live-up $((applied - committed))
  else
    check "live round $i: the app applied the peer's category edit" 1
  fi
  sleep 0.3
done
for i in $(seq 1 "$ROUNDS"); do
  before_peer="$(count "$WATCH_LOG" "applied ledger_transaction .* note \"mac-$i\"")"
  before_app="$(count "$APP_LOG" "local-edit ledger_transaction .* note \"mac-$i\"")"
  echo "{\"tx\":\"$TX\",\"note\":\"mac-$i\"}" >&3
  if wait_for "$APP_LOG" "local-edit ledger_transaction .* note \"mac-$i\"" "$before_app" 5 \
     && wait_for "$WATCH_LOG" "applied ledger_transaction .* note \"mac-$i\"" "$before_peer" 10; then
    edit_ms="$(last_ms "$APP_LOG" "local-edit ledger_transaction .* note \"mac-$i\"")"
    peer_ms="$(last_ms "$WATCH_LOG" "applied ledger_transaction .* note \"mac-$i\"")"
    record live-down $((peer_ms - edit_ms))
  else
    check "live round $i: the peer applied the Mac's note edit" 1
  fi
  sleep 0.3
done
kill "$WATCH_PID" 2>/dev/null; wait "$WATCH_PID" 2>/dev/null; WATCH_PID=""

# ---------------------------------------------------------------------------------------------------------------- 4. app quit
say "== 4. app quit: peer edits wait in the agent's mailbox, the relaunched app applies them"
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
sleep 1
out="$("$PEER" set-note --vault "$PEER_DIR" --password "$PASSWORD" --tx "$TX" --note "typed-while-quit" --host 127.0.0.1 --port "$LOCAL_PORT" 2>&1)"
echo "$out" | sed 's/^/    peer: /'
echo "$out" | grep -q '"opsSent":1'; check "the agent accepted the peer's batch into its mailbox with no app running" $?
before="$(count "$APP_LOG" 'remote-op ledger_transaction .* note "typed-while-quit"')"
RELAUNCH_MS="$(now_ms)"
launch_app
note "app relaunched, pid $APP_PID"
if wait_for "$APP_LOG" 'remote-op ledger_transaction .* note "typed-while-quit"' "$before" 60; then
  applied="$(last_ms "$APP_LOG" 'remote-op ledger_transaction .* note "typed-while-quit"')"
  note "mailbox batch applied $((applied - RELAUNCH_MS)) ms after relaunch (includes app start, vault unlock, XPC attach)"
  check "the relaunched app applied the batch from the mailbox" 0
else
  check "the relaunched app applied the batch from the mailbox" 1
fi
wait_for "$APP_LOG" '^[0-9]+ pairing code=' 1 60 >/dev/null 2>&1

# ---------------------------------------------------------------------------------------------------------------- 5. outbox
say "== 5. Mac edit published while attached, app quit, peer fetches from the agent's outbox"
echo "{\"tx\":\"$TX\",\"note\":\"mac-outbox\"}" >&3
wait_for "$APP_LOG" 'local-edit ledger_transaction .* note "mac-outbox"' 0 10 || die "the app did not take the edit"
sleep 1.5   # debounce (300 ms) + publish to the outbox
kill "$APP_PID" 2>/dev/null; wait "$APP_PID" 2>/dev/null; APP_PID=""
sleep 1
FETCH_T0="$(now_ms)"
"$PEER" sync --vault "$PEER_DIR" --password "$PASSWORD" --host 127.0.0.1 --port "$LOCAL_PORT" >"$WORK/fetch.log" 2>&1
FETCH_T1="$(now_ms)"
sed 's/^/    peer: /' "$WORK/fetch.log"
NOTE="$(dump | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["transactions"][0]["note"])')"
[ "$NOTE" = "mac-outbox" ]; check "the peer received the Mac's edit from the outbox while the app was not running (note = $NOTE)" $?
note "outbox fetch (dial + hello + batch + ack + idle wait) $((FETCH_T1 - FETCH_T0)) ms"

# relaunch once more so cleanup can switch sync off through the app (unregisters the agent)
launch_app
wait_for "$APP_LOG" '^[0-9]+ pairing code=' 2 60 >/dev/null 2>&1 || note "(relaunch before cleanup: no new pairing line)"

# ---------------------------------------------------------------------------------------------------------------- summary
say ""
say "== latency (ms, this Mac's clock, path: Mac -> ssh -> $SSH_HOST -> tailnet -> Mac)"
python3 - "$WORK" <<'EOF'
import glob, os, statistics, sys
names = {
    "one-shot": "peer -> Mac, one shot (dial+handshake+push)",
    "live-up": "peer -> Mac, session open (peer polls 50 ms)",
    "live-down": "Mac -> peer, live relay (300 ms debounce)",
}
print(f"  {'path':48} {'n':>3} {'min':>6} {'median':>7} {'p95':>6} {'max':>6}")
for key in ("one-shot", "live-up", "live-down"):
    path = os.path.join(sys.argv[1], f"lat-{key}.txt")
    values = sorted(int(x) for x in open(path).read().split()) if os.path.exists(path) else []
    if not values:
        print(f"  {names[key]:48} no samples")
        continue
    p95 = values[min(len(values) - 1, int(round(0.95 * (len(values) - 1))))]
    print(f"  {names[key]:48} {len(values):>3} {values[0]:>6} {int(statistics.median(values)):>7} {p95:>6} {values[-1]:>6}")
EOF
