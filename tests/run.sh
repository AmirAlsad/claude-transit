#!/bin/bash
#
# Scenario tests for claude-transit. pmset, ioreg, sudo and osascript are
# replaced by stubs in tests/stubs, so this runs anywhere (Linux or macOS)
# and never touches real power settings.
#
#   tests/run.sh [path/to/bash]    # e.g. /bin/bash on a Mac is bash 3.2
#
# Needs perl (for fake Claude processes); uses setsid if it's available.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd)
BASH_UT=${1:-/bin/bash}
T=$(mktemp -d "${TMPDIR:-/tmp}/claude-transit-test.XXXXXX")

export HOME="$T/home" STUB_STATE="$T/state" PATH="$ROOT/tests/stubs:$PATH"
export CLAUDE_TRANSIT_INTERVAL=1 CLAUDE_TRANSIT_GRACE=3 CLAUDE_TRANSIT_SUDOERS="$T/sudoers"
export CLAUDE_TRANSIT_HEAT_EVERY=1 CLAUDE_TRANSIT_NET_EVERY=1
# If these tests run inside Claude Code, its own command shells carry the real
# marker. Use a test-only one so only the fake commands below count.
export CLAUDE_TRANSIT_CMD_MARKER=/fake-claude/shell-snapshots/
unset CLAUDE_TRANSIT_STATE CLAUDE_TRANSIT_LOG CLAUDE_TRANSIT_SETTINGS CLAUDE_TRANSIT_TIMEOUT_SECS
unset CLAUDE_TRANSIT_NTFY CLAUDE_TRANSIT_NOTIFY_CMD CLAUDE_TRANSIT_WAIT_SECS CLAUDE_TRANSIT_AGENT_QUIET
# No hold for waiting sessions unless a test asks for one ("Waiting on you").
export CLAUDE_TRANSIT_WAIT=0

LOG="$HOME/Library/Logs/claude-transit.log"
SESS="$HOME/.local/state/claude-transit/sessions"
WFILE="$HOME/.local/state/claude-transit/watcher"
SETTINGS="$HOME/.claude/settings.json"
mkdir -p "$HOME/.claude" "$STUB_STATE"

PASS=0 FAIL=0
ok()      { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad()     { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check()   { local d=$1; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }
section() { printf '\n%s\n' "$1"; }

ct()   { "$BASH_UT" "$ROOT/bin/claude-transit" "$@"; }
hook() {  # session event [raw json]
  local json=${3:-'{"session_id":"'"$1"'","transcript_path":"/x","tool_response":{"stdout":"{\"session_id\":\"evil\"}"}}'}
  printf '%s' "$json" | "$BASH_UT" "$ROOT/bin/claude-transit-hook" "$2"
}
sd()        { cat "$STUB_STATE/sleepdisabled" 2>/dev/null || echo 0; }
lid()       { echo "$1" > "$STUB_STATE/lid"; }
wpid()      { awk '{print $1}' "$WFILE" 2>/dev/null; }
disarmed()  { grep -q "DISARMED \[$1\]" "$LOG" 2>/dev/null; }
not_disarmed() { ! grep -q "DISARMED" "$LOG" 2>/dev/null; }
event()     { grep -q "$1" "$STUB_STATE/events" 2>/dev/null; }
no_event()  { ! event "$1"; }
is()        { [ "$1" = "$2" ]; }
all()       { eval "$1"; }
has()       { case $1 in *"$2"*) return 0 ;; esac; return 1; }
sd_is()     { [ "$(sd)" = "$1" ]; }
alive()     { case $(ps -o stat= -p "$1" 2>/dev/null) in ''|*Z*) return 1 ;; esac; }  # zombies count as dead
dead()      { ! alive "$1"; }
# Count top-level instances only: the watcher briefly forks copies of itself
# (subshells for checks), which share its command line.
count_procs() {
  ps -A -o pid=,ppid=,command= | PAT="$ROOT/bin/claude-transit $1" awk '
    index($0, ENVIRON["PAT"]) { parent[$1] = $2 }
    END { n = 0; for (p in parent) if (!(parent[p] in parent)) n++; print n }'
}
watchers()  { count_procs _watch; }
guardians() { count_procs _guard; }
gpid()      { awk '{print $1}' "$HOME/.local/state/claude-transit/guard" 2>/dev/null; }

wait_for() {  # seconds command...
  local n=$(($1 * 10))
  shift
  while [ $n -gt 0 ]; do
    "$@" && return 0
    sleep 0.1
    n=$((n - 1))
  done
  return 1
}

hooks_on()  { printf '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"x/claude-transit-hook stop"}]}]}}\n' > "$SETTINGS"; }
hooks_off() { printf '{"model":"opus"}\n' > "$SETTINGS"; }

reset() {
  pkill -KILL -f "$ROOT/bin/claude-transit _guard" 2>/dev/null
  pkill -KILL -f "$ROOT/bin/claude-transit _watch" 2>/dev/null
  sleep 0.2
  rm -rf "$LOG" "$STUB_STATE/events" "$SESS" "$WFILE"
  echo 0 > "$STUB_STATE/sleepdisabled"
  rm -f "$STUB_STATE/batt" "$STUB_STATE/thermal" "$STUB_STATE/net" "$STUB_STATE/ip" "$STUB_STATE/ssid"
  lid No
  printf '%s\n' '-a disablesleep 1' '-a disablesleep 0' > "$STUB_STATE/sudo_rule"
  touch "$T/sudoers"
  hooks_on
}

# A stand-in for a Claude Code process: a long-lived perl process that runs
# the hook through "sh -c ... | bash hook", like Claude Code's shell form.
FAKE_PIDS=""
fake_claude() {  # session -> prints the fake Claude pid
  perl -e '$SIG{TERM} = sub { exit 0 }; my $p = fork; if (!$p) { exec @ARGV; exit 127 } waitpid($p, 0); sleep 3600' \
    sh -c "printf '{\"session_id\":\"$1\"}' | '$BASH_UT' '$ROOT/bin/claude-transit-hook' prompt; true" \
    </dev/null >/dev/null 2>&1 &
  FAKE_PIDS="$FAKE_PIDS $!"
  echo $!
}

# A fake Claude process (for session $1) that has also started a command the
# way Claude Code does: a shell whose command line names a shell snapshot.
# Prints "<fake claude pid> <command shell pid>".
fake_claude_cmd() {  # session command
  local f="$T/cmdpid.$1"
  rm -f "$f"
  CMDPIDFILE=$f perl -e '
    my ($sid, $hook, $bash, $cmd, $snap) = @ARGV;
    our $bg;
    $SIG{TERM} = sub { kill "TERM", $bg if $bg; exit 0 };
    my $p = fork;
    if (!$p) { exec "sh", "-c", "printf %s \"{\\\"session_id\\\":\\\"$sid\\\"}\" | $bash $hook prompt; true"; exit 127 }
    waitpid($p, 0);
    $bg = fork;
    if (!$bg) { exec $bash, "-c", "source $snap 2>/dev/null || true && eval \x27$cmd\x27 < /dev/null && true"; exit 127 }
    open(F, ">", $ENV{CMDPIDFILE}); print F $bg; close F;
    sleep 3600' "$1" "$ROOT/bin/claude-transit-hook" "$BASH_UT" "$2" "$T/fake-claude/shell-snapshots/snapshot-zsh-1.sh" \
    </dev/null >/dev/null 2>&1 &
  FAKE_PIDS="$FAKE_PIDS $!"
  wait_for 3 [ -s "$f" ]
  echo "$! $(cat "$f" 2>/dev/null)"
}

cleanup() {
  pkill -KILL -f "$ROOT/bin/claude-transit _guard" 2>/dev/null
  pkill -KILL -f "$ROOT/bin/claude-transit _watch" 2>/dev/null
  for p in $FAKE_PIDS; do kill "$p" 2>/dev/null; done
  rm -rf "$T"
}
trap cleanup EXIT

printf 'claude-transit tests with %s (%s)\n' "$BASH_UT" "$("$BASH_UT" -c 'echo $BASH_VERSION')"

# ------------------------------------------------------------------ hook script
section "Hook script"
reset
out=$(hook s1 prompt)
check "prints nothing (UserPromptSubmit stdout would reach Claude)" is "$out" ""
read -r st pid _ < "$SESS/s1"
check "prompt -> busy" is "$st" busy
check "records a Claude pid" [ "${pid:-0}" -gt 1 ]
check "uses the top-level session_id, not one inside tool output" [ ! -e "$SESS/evil" ]
before=$(cat "$SESS/s1"); sleep 1.1; hook s1 tool
check "tool while busy leaves the file alone (fast path)" is "$(cat "$SESS/s1")" "$before"
hook s1 stop
read -r st pid2 _ < "$SESS/s1"
check "stop -> idle, keeps the pid" is "$st $pid2" "idle $pid"
hook s1 wait
check "wait -> waiting" is "$(awk '{print $1}' "$SESS/s1")" waiting
hook s1 tool
check "tool after wait -> busy again" is "$(awk '{print $1}' "$SESS/s1")" busy
hook s1 wait; hook s1 idle
check "idle_prompt doesn't overwrite an unanswered question" is "$(awk '{print $1}' "$SESS/s1")" waiting
hook s1 prompt; hook s1 idle
check "idle_prompt otherwise -> idle" is "$(awk '{print $1}' "$SESS/s1")" idle
hook s1 end
check "end removes the session" [ ! -e "$SESS/s1" ]
r=clean; for f in "$SESS"/.[!.]*; do [ -e "$f" ] && r=leftover; done
check "no temp files left in the sessions folder" is "$r" clean
hook x prompt '{"session_id": "spaced-1", "cwd": "/tmp/my project"}'
check "accepts spaces around the colon" [ -f "$SESS/spaced-1" ]
check "records the project folder, spaces and all" is "$(cut -d' ' -f4- "$SESS/spaced-1")" "/tmp/my project"
hook x tool '{"session_id":"spaced-1"}'; hook x stop '{"session_id":"spaced-1"}'
check "  and keeps it when a later event has no cwd" is "$(cut -d' ' -f4- "$SESS/spaced-1")" "/tmp/my project"
printf 'not json' | "$BASH_UT" "$ROOT/bin/claude-transit-hook" tool; rc=$?
check "garbage input: exit 0" is "$rc" 0
hook x prompt '{"session_id":"../../escape"}'; rc=$?
check "rejects a session_id with path characters (exit 0, no file)" all '[ "$rc" = 0 ] && [ ! -e "$HOME/.local/escape" ]'
hook s9 bogus; rc=$?
check "unknown event: exit 0, no file" all '[ "$rc" = 0 ] && [ ! -e "$SESS/s9" ]'
fp=$(fake_claude fk1)
wait_for 3 [ -f "$SESS/fk1" ]
check "pid is the Claude process, found past the sh -c wrapper" is "$(awk '{print $2}' "$SESS/fk1" 2>/dev/null)" "$fp"
kill "$fp" 2>/dev/null

reset
hook x prompt '{"session_id":"sa1","cwd":"/tmp/p"}'
hook x tool '{"session_id":"sa1","agent_id":"ag1","agent_type":"general-purpose","hook_event_name":"PreToolUse","tool_name":"Bash"}'
check "a subagent's tool call goes to its own file" is "$(awk '{print $1}' "$SESS/sa1@ag1" 2>/dev/null)" busy
hook x stop '{"session_id":"sa1","hook_event_name":"Stop"}'
check "  the main turn ending leaves the subagent's file alone" all '[ "$(awk "{print \$1}" "$SESS/sa1")" = idle ] && [ "$(awk "{print \$1}" "$SESS/sa1@ag1")" = busy ]'
hook x subend '{"session_id":"sa1","agent_id":"ag1","hook_event_name":"SubagentStop"}'
check "  SubagentStop removes it" all '[ ! -e "$SESS/sa1@ag1" ] && [ -e "$SESS/sa1" ]'
hook x substart '{"session_id":"sa2","agent_id":"ag2","hook_event_name":"SubagentStart"}'
check "a subagent reporting first also creates the session's file, as idle" is "$(awk '{print $1}' "$SESS/sa2" 2>/dev/null)" idle
hook x end '{"session_id":"sa2","hook_event_name":"SessionEnd"}'
check "  SessionEnd removes both" all '[ ! -e "$SESS/sa2" ] && [ ! -e "$SESS/sa2@ag2" ]'
hook x tool '{"session_id":"sa3","hook_event_name":"PreToolUse","tool_name":"X","tool_input":{"agent_id":"fake"}}'
check "an agent_id inside a tool's input is ignored" all '[ -e "$SESS/sa3" ] && [ ! -e "$SESS/sa3@fake" ]'

# ------------------------------------------------------------------ arming
section "Arming"
reset
rm -f "$STUB_STATE/sudo_rule"
out=$(ct 5 2>&1); rc=$?
check "refuses without the sudoers rule" [ "$rc" = 1 ]
check "  and says why" has "$out" "sudo wants a password"
check "  and leaves sleep alone" is "$(sd)" 0
sleep 0.3
check "  and leaves no watcher behind" is "$(watchers)" 0

reset
ct 0 >/dev/null 2>&1; rc1=$?; ct 241 >/dev/null 2>&1; rc2=$?; ct soon >/dev/null 2>&1; rc3=$?
check "rejects 0, 241 and non-numbers" [ "$rc1$rc2$rc3" = 111 ]
check "  without arming" is "$(sd)" 0

reset
hook s1 prompt
out=$(ct 08 2>&1); rc=$?
check "arms (leading zero is decimal)" [ "$rc" = 0 ]
check "  SleepDisabled is 1" is "$(sd)" 1
check "  reports 8 minutes" has "$out" "armed for 8 min"
check "  shows the battery note" has "$out" "Battery: 85%, discharging, 4:12 remaining. Make sure"
check "  shows the heat reminder" has "$out" "Never a sleeve"
check "  shows Claude working" has "$out" "Claude: 1 working"
check "  log has ARMED with battery" grep -q "ARMED for 8 min .*battery 85%" "$LOG"
st=$(ct status)
check "status: armed" has "$st" "Guard:     armed"
check "status: sleep OFF" has "$st" "Sleep:     OFF"
w1=$(wpid)
ct 5 >/dev/null
w2=$(wpid)
check "re-arming replaces the old watcher" all '[ -n "$w2" ] && [ "$w1" != "$w2" ] && dead "$w1"'
check "  exactly one watcher running" is "$(watchers)" 1
check "  and one guardian" is "$(guardians)" 1
check "  replacing didn't wake the old guardian" all '! grep -q GUARDIAN "$LOG"'
check "  sleep still disabled" is "$(sd)" 1
out=$(ct off)
check "off restores sleep" is "$(sd)" 0
check "  and the watcher is gone" wait_for 2 dead "$w2"
check "  and the guardian" wait_for 2 is "$(guardians)" 0
check "  log shows the manual stop" disarmed S

reset
out=$(ct 5 2>&1)
check "no working session at arm time -> note" has "$out" "no Claude session is working right now"
ct off >/dev/null

reset
hooks_off
out=$(ct 5 2>&1)
check "hooks missing -> early finish turned off, with a note" has "$out" "Early finish is off"
check "  status agrees" has "$(ct status)" "early finish off"
lid Yes
sleep 5
check "  so a closed lid with no sessions stays awake" not_disarmed
ct off >/dev/null

# ------------------------------------------------------------------ vector A
section "Vector A: lid reopened"
reset
hook s1 prompt
ct 5 >/dev/null
sleep 2.5
check "lid open the whole time: stays armed" not_disarmed
lid Yes; sleep 1.5; lid No
check "close then open -> disarm A" wait_for 4 disarmed A
check "  sleep restored" is "$(sd)" 0
check "  notification shown" wait_for 3 event "Lid reopened"
check "  no sleepnow (you're using it)" no_event sleepnow

# ------------------------------------------------------------------ vector B
section "Vector B: Claude finished"
reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
sleep 5
check "busy session + closed lid: stays armed past the grace period" not_disarmed
hook s1 stop
check "turn ends -> disarm B after the grace period" wait_for 7 disarmed B
check "  sleep restored" is "$(sd)" 0
check "  sleepnow requested (lid is closed)" wait_for 3 event sleepnow
check "  log explains the countdown" grep -q "restoring sleep in 3s unless one starts" "$LOG"

reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
hook s1 stop; sleep 1.5; hook s1 prompt
sleep 4
check "new turn inside the grace period cancels the countdown" not_disarmed
check "  and says so in the log" grep -q "working again" "$LOG"
ct off >/dev/null

reset
hook s1 prompt; hook s2 prompt
ct 5 >/dev/null
lid Yes
hook s1 stop
sleep 5
check "two sessions: one finishing isn't enough" not_disarmed
hook s2 stop
check "  both finished -> disarm B" wait_for 7 disarmed B

reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
sleep 1.5
hook s1 wait
check "a question asked after the lid closed counts as finished" wait_for 7 disarmed B

reset
hook s1 prompt
hook s1 wait
out=$(ct 5 2>&1)
check "arming while a session is asking something -> note" has "$out" "Waiting sessions don't keep"
lid Yes
check "a question asked before the lid closed doesn't keep it awake either" wait_for 7 disarmed B

reset
hook s1 prompt; hook s2 prompt
ct 5 >/dev/null
lid Yes
hook s2 wait
sleep 5
check "one session waiting, one working: stays awake for the working one" not_disarmed
hook s1 stop
check "  working one finishes: disarm B despite the waiting one" wait_for 7 disarmed B

reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
hook s1 wait; sleep 1; hook s1 tool
sleep 4
check "a tool call after the prompt means it's working again" not_disarmed
ct off >/dev/null

reset
fp=$(fake_claude s3)
wait_for 3 [ -f "$SESS/s3" ]
ct 5 >/dev/null
lid Yes
sleep 4.5
check "fake Claude alive and busy: stays armed" not_disarmed
kill "$fp"
check "Claude process dies mid-turn -> its stale report is ignored -> disarm B" wait_for 7 disarmed B
check "  stale report deleted" [ ! -e "$SESS/s3" ]

reset
ct 5 --no-early >/dev/null
lid Yes
sleep 5
check "--no-early: closed lid, nothing working, stays armed" not_disarmed
ct off >/dev/null

# ------------------------------------------------------------------ vector C
section "Vector C: timeout"
reset
hook s1 prompt
CLAUDE_TRANSIT_TIMEOUT_SECS=4 ct 1 >/dev/null
lid Yes
check "busy session, lid closed: timeout still fires" wait_for 8 disarmed C
check "  sleep restored" is "$(sd)" 0
check "  sleepnow requested (lid is closed)" wait_for 3 event sleepnow

reset
CLAUDE_TRANSIT_TIMEOUT_SECS=3 ct 1 --no-early >/dev/null
check "timeout with the lid open" wait_for 7 disarmed C
check "  no sleepnow" no_event sleepnow

# ------------------------------------------------------------------ robustness
section "Robustness"
reset
hook s1 prompt
ct 5 >/dev/null
w=$(wpid)
kill -HUP "$w"; sleep 1.5
check "SIGHUP (terminal closed) is ignored" alive "$w"
check "  sleep still disabled" is "$(sd)" 1
kill -TERM "$w"
check "SIGTERM restores sleep" wait_for 3 sd_is 0
check "  and logs it" wait_for 2 grep -q "stopped by SIGTERM" "$LOG"
sleep 1
check "  the guardian sees a clean exit and stays quiet" all '! grep -q GUARDIAN "$LOG" && [ "$(guardians)" = 0 ]'

if command -v setsid >/dev/null 2>&1; then
  reset
  hook s1 prompt
  setsid "$BASH_UT" -c "'$BASH_UT' '$ROOT/bin/claude-transit' 5 >/dev/null 2>&1; sleep 30" &
  launcher=$!
  wait_for 5 sd_is 1
  w=$(wpid)
  pg=$(ps -o pgid= -p "$launcher" | tr -d ' ')
  kill -TERM -- "-$pg" 2>/dev/null
  sleep 1.5
  check "killing the launching process group doesn't take the watcher with it" alive "$w"
  ct off >/dev/null
fi

reset
hook s1 prompt
ct 5 >/dev/null
check "arming starts one guardian with the watcher" all '[ "$(guardians)" = 1 ] && [ "$(watchers)" = 1 ]'
check "status shows the guardian" has "$(ct status)" "Guardian:  pid"
lid Yes; sleep 1.5
kill -KILL "$(wpid)"
check "kill -9 on the watcher: the guardian restores sleep" wait_for 3 sd_is 0
check "  logs what happened" grep -q "GUARDIAN: watcher (pid [0-9]*) ended (killed by signal 9) with sleep still off; restored sleep" "$LOG"
check "  puts the Mac to sleep (lid closed)" wait_for 3 event sleepnow
check "  and exits" wait_for 2 is "$(guardians)" 0

reset
hook s1 prompt
ct 5 >/dev/null
kill -KILL "$(gpid)"; sleep 0.5
check "kill -9 on the guardian alone: the watcher keeps guarding" all '[ "$(watchers)" = 1 ] && [ "$(sd)" = 1 ]'
check "  status says the guardian is gone" has "$(ct status)" "Guardian:  not running"
lid Yes; sleep 1.5; lid No
check "  and the lid still disarms it" wait_for 4 disarmed A

reset
hook s1 prompt
ct 5 >/dev/null
g=$(gpid); w=$(wpid)
kill -KILL "$g"; kill -KILL "$w"; sleep 0.5
check "kill -9 on both leaves sleep disabled (nothing is left to clean up)" is "$(sd)" 1
out=$(ct check 2>&1)
check "  check warns" has "$out" "sleep is disabled but no guard is running"
check "  status warns" has "$(ct status)" "Sleep is off but no guard is running"
ct off >/dev/null
check "  off restores it" is "$(sd)" 0
check "check is silent when all is well" is "$(ct check 2>&1)" ""
echo 1 > "$STUB_STATE/sleepdisabled"
ct check --fix
check "check --fix restores sleep left off with no guard" is "$(sd)" 0
check "  and says so" event "left off"
hook s1 prompt
ct 5 >/dev/null
ct check --fix
check "check --fix leaves a running guard alone" is "$(sd)" 1
ct off >/dev/null

# ------------------------------------------------------------------ several sessions
section "Several sessions"
reset
hook x prompt '{"session_id":"m1","cwd":"'"$HOME"'/code/webapp"}'
hook x prompt '{"session_id":"m2","cwd":"'"$HOME"'/code/ios-app"}'
hook x prompt '{"session_id":"m3","cwd":"/srv/other"}'; hook x stop '{"session_id":"m3"}'
out=$(ct 5 2>&1)
check "arm lists every session by project" all '[[ $out == *"~/code/webapp"*working* && $out == *"~/code/ios-app"*working* && $out == *"/srv/other"*idle* ]]'
check "  with a summary line" has "$out" "Claude: 2 working, 1 idle"
lid Yes
hook x stop '{"session_id":"m1"}'
sleep 5
check "one of two working sessions finishing: stays awake" not_disarmed
hook x stop '{"session_id":"m2"}'
check "  both finished (the idle third doesn't matter): disarm B" wait_for 7 disarmed B
check "status shows each session's Claude pid" has "$(ct status)" "pid "

# ------------------------------------------------------------------ commands
section "Commands Claude is running"
reset
set -- $(fake_claude_cmd bg1 "sleep 600")
fc=$1 cmdpid=$2
wait_for 3 [ -f "$SESS/bg1" ]
hook bg1 stop
out=$(ct 5 2>&1)
check "arm lists the running command" all '[[ $out == *"running a command"* && $out == *'"'"'$ sleep 600'"'"'* ]]'
check "  with the never-ending-command note" has "$out" "keep the Mac awake until they finish"
check "  and doesn't claim nothing is working" all '[[ $out != *"no Claude session is working right now"* ]]'
check "status shows it too" has "$(ct status)" '$ sleep 600'
lid Yes
sleep 5
check "turn ended but its command runs on: stays awake" not_disarmed
check "  log names the command" grep -q "commands running: sleep 600" "$LOG"
kill "$cmdpid"
check "command finishes: disarm B after the grace period" wait_for 7 disarmed B
check "  log notes it finished" grep -q "commands running: none" "$LOG"
kill "$fc" 2>/dev/null

reset
set -- $(fake_claude_cmd bg2 "sleep 601")
fc=$1
hook x prompt '{"session_id":"other"}'; hook x stop '{"session_id":"other"}'
"$BASH_UT" -c "exec -a 'bash -c source $T/fake-claude/shell-snapshots/x.sh && eval sleep' sleep 600" &
stray=$!
FAKE_PIDS="$FAKE_PIDS $stray"
wait_for 3 [ -f "$SESS/bg2" ]
hook bg2 stop
ct 5 >/dev/null
check "a command under another process isn't counted" all '! ct status | grep -q "x.sh"'
check "  but this session's is" has "$(ct status)" '$ sleep 601'
kill "$fc" "$stray" 2>/dev/null
ct off >/dev/null

reset
set -- $(fake_claude_cmd bg3 'export MYAPP_API_TOKEN="0A1B2C3D-4E5F-6789-ABCD-EF0123456789" && sleep 600')
fc=$1
wait_for 3 [ -f "$SESS/bg3" ]
hook bg3 stop
out=$(ct 5 2>&1)
check "a variable's value is hidden in the label" has "$out" '$ MYAPP_API_TOKEN=… sleep 600'
check "  and never reaches the log" all '! grep -q 0A1B2C3D "$LOG"'
kill "$fc" 2>/dev/null
ct off >/dev/null

reset
set -- $(fake_claude_cmd bg5 ' SECRET_VAR="hunter2" && sleep 603')
fc=$1
wait_for 3 [ -f "$SESS/bg5" ]
hook bg5 stop
st=$(ct status)
check "a variable's value is hidden even after a leading space" all '[[ $st == *'"'"'$ SECRET_VAR=… sleep 603'"'"'* && $st != *hunter2* ]]'
kill "$fc" 2>/dev/null

reset
set -- $(fake_claude_cmd bg4 "cd $HOME && sleep 602")
fc=$1
wait_for 3 [ -f "$SESS/bg4" ]
hook bg4 stop
check "a leading cd is left out of the label" has "$(ct status)" '$ sleep 602'
kill "$fc" 2>/dev/null

reset
set -- $(fake_claude_cmd tf1 "tail -n +1 -f /dev/null")
fc=$1
set -- $(fake_claude_cmd tf2 "tail -f /dev/null | grep -m1 ready")
fc2=$1
wait_for 3 [ -f "$SESS/tf1" ]
wait_for 3 [ -f "$SESS/tf2" ]
hook tf1 stop
st=$(ct status)
check "a bare tail -f (a Monitor) isn't counted as work" all '[[ $st != *"tail -n +1"* ]]'
check "  but tail -f piped into something that ends is" has "$st" '$ tail -f /dev/null | grep -m1 ready'
kill "$fc2" 2>/dev/null
hook tf2 stop
ct 5 >/dev/null
lid Yes
check "  so the Mac sleeps with only a Monitor running" wait_for 7 disarmed B
kill "$fc" 2>/dev/null

# ------------------------------------------------------------------ network
section "Network"
reset
echo 172.20.10.3 > "$STUB_STATE/ip"
hook s1 prompt
ct 5 >/dev/null
check "ARMED line names the network" grep -q "ARMED .*network iPhone hotspot" "$LOG"
check "first check logged as online" wait_for 3 grep -q "network: iPhone hotspot, online | lid open | armed" "$LOG"
lid Yes
sleep 1.5
echo down > "$STUB_STATE/net"
check "a drop is logged with the lid state" wait_for 4 grep -q "network: iPhone hotspot, api.anthropic.com unreachable | lid closed" "$LOG"
sleep 2
rm -f "$STUB_STATE/net"
check "recovery is logged with how long it was down" wait_for 4 grep -q "network: iPhone hotspot, online | lid closed | armed .* | back after about 0m0[1-9]s" "$LOG"
echo none > "$STUB_STATE/ip"; echo down > "$STUB_STATE/net"
check "losing Wi-Fi entirely is logged" wait_for 4 grep -q "network: no Wi-Fi, api.anthropic.com unreachable" "$LOG"
lid No
check "disarm summarises drops and networks" wait_for 4 grep -q "DISARMED \[A\].*network: 2 drop(s), offline about .* in all, longest .* (iPhone hotspot, no Wi-Fi)" "$LOG"

reset
echo 10.31.172.49 > "$STUB_STATE/ip"
ct 5 --no-early >/dev/null
check "ordinary Wi-Fi with a hidden name shows its address" wait_for 3 grep -q "network: Wi-Fi 10.31.172.49, online" "$LOG"
echo MIT > "$STUB_STATE/ssid"; echo 10.31.172.50 > "$STUB_STATE/ip"
check "  and its name when macOS shares it" wait_for 4 grep -q 'network: Wi-Fi "MIT", online' "$LOG"
ct off >/dev/null
check "no drops: says so" grep -q 'network: no drops (Wi-Fi 10.31.172.49, Wi-Fi "MIT")' "$LOG"

# ------------------------------------------------------------------ trip summary
section "Trip summary"
ev() {  # session hook-event [tool]
  hook x tool '{"session_id":"'"$1"'","hook_event_name":"'"$2"'","tool_name":"'"${3:-}"'"}'
}
reset
hook s1 prompt
check "hooks record nothing while no guard is armed" all '[ ! -e "$HOME/.local/state/claude-transit/activity" ]'
set -- $(fake_claude_cmd t1 "sleep 600")
fc1=$1 cmd1=$2
ct 5 --no-early >/dev/null
ev s1 PostToolUse Bash
check "PostToolUse before the lid closes is recorded but not counted" grep -q "s1 PostToolUse Bash" "$HOME/.local/state/claude-transit/activity"
sleep 1.1
lid Yes
sleep 1.5
ev s1 PostToolUse Bash; ev s1 PostToolUse Bash; ev s1 PostToolUse Edit; ev s1 PostToolUse Read
ev s2 PostToolUse Bash; ev s1 Stop; ev s1 SubagentStop
set -- $(fake_claude_cmd t2 'yes > /dev/null & sleep 3; kill $!; wait')
fc2=$1
sleep 2
kill "$cmd1"
sleep 4
lid No
check "trip ends with a TRIP line" wait_for 4 grep -q "^.* TRIP lid closed" "$LOG"
trip=$(grep " TRIP " "$LOG")
# s1 and s2 report tool calls; the second fake command's session (t2) sends its prompt mid-trip.
check "  counts Claude's tool calls while the lid was shut, top tools first" has "$trip" "Claude: 5 tool calls (Bash 3, Edit 1, Read 1), 1 turn finished, 1 subagent finished, 3 sessions"
check "  command running from before the lid closed, finished during the trip" all '[[ $trip == *"sleep 600 used 0m00s CPU, finished by "* ]]'
check "  command that started and finished during the trip, with its CPU time" all '[[ $trip =~ "yes > /dev/null & sleep 3; kill \$!; wait used 0m0"[1-4]"s CPU, finished by" ]]'
check "  heat peak, battery and network" all '[[ $trip == *"heat peak nominal | battery 85% -> 85% | network: no drops"* ]]'
check "activity file removed after the trip" all '[ ! -e "$HOME/.local/state/claude-transit/activity" ]'
kill "$fc1" "$fc2" 2>/dev/null

reset
set -- $(fake_claude_cmd t3 "sleep 600")
fc3=$1
ct 5 --no-early >/dev/null
lid Yes; sleep 2
ct off >/dev/null
check "a command still running at the end says so" grep -q "TRIP .*sleep 600 used 0m00s CPU, still running" "$LOG"
check "  no Claude activity says so" grep -q "TRIP .*Claude: no activity" "$LOG"
kill "$fc3" 2>/dev/null

reset
ct 5 >/dev/null; sleep 1.5; ct off >/dev/null
check "no TRIP line if the lid never closed" all '! grep -q " TRIP " "$LOG"'

# ------------------------------------------------------------------ heat
section "Vector H: heat"
reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
check "ARMED line records the starting heat" grep -q "ARMED .*heat nominal" "$LOG"
echo 1 > "$STUB_STATE/thermal"; sleep 2.5
echo 2 > "$STUB_STATE/thermal"; sleep 2.5
check "fair and serious: stays armed" not_disarmed
check "  each transition logged with the old state" all 'grep -q "heat fair (was nominal) | lid closed | armed" "$LOG" && grep -q "heat serious (was fair)" "$LOG"'
echo 3 > "$STUB_STATE/thermal"
check "critical, even with a busy session: disarm H" wait_for 4 disarmed H
check "  transition to critical logged" grep -q "heat critical (was serious)" "$LOG"
check "  sleep restored" is "$(sd)" 0
check "  sleepnow (lid closed)" wait_for 3 event sleepnow

reset
hook s1 prompt
ct 5 >/dev/null
echo 3 > "$STUB_STATE/thermal"
check "critical with the lid open: disarm H" wait_for 4 disarmed H
check "  notification instead of sleepnow" all 'event "critical heat" && no_event sleepnow'

reset
echo garbage > "$STUB_STATE/thermal"
hook s1 prompt
ct 5 >/dev/null
sleep 2.5
check "unreadable heat: logged as unknown, no action" all 'not_disarmed && grep -q "heat unknown" "$LOG"'
ct off >/dev/null

# ------------------------------------------------------------------ subagents
section "Subagents"
sub() {  # session agent event
  hook x "$3" '{"session_id":"'"$1"'","agent_id":"'"$2"'","hook_event_name":"X"}'
}
reset
hook s1 prompt
ct 5 >/dev/null
lid Yes
sub s1 bg tool
hook s1 stop
sleep 5
check "main turn over, background subagent still going: stays awake" not_disarmed
check "  status says so" has "$(ct status)" "working (subagent)"
sub s1 bg subend
check "  subagent finishes: disarm B" wait_for 7 disarmed B

reset
hook s1 prompt
sub s1 bg tool
hook s1 stop
CLAUDE_TRANSIT_AGENT_QUIET=3 ct 5 >/dev/null
lid Yes
check "a subagent that goes quiet (stopped without SubagentStop) stops counting" wait_for 9 disarmed B

# ------------------------------------------------------------------ waiting on you
section "Waiting on you"
reset
hook s1 prompt
CLAUDE_TRANSIT_WAIT_SECS=6 ct 5 >/dev/null
lid Yes; sleep 1.5
hook s1 wait
sleep 4
check "a question keeps the Mac awake while the hold lasts" not_disarmed
check "  logged once, with the time left" is "$(grep -c 'is waiting on you; staying awake up to' "$LOG")" 1
check "  no answer: disarm B once the hold is over" wait_for 10 disarmed B
check "  log says it stopped waiting" grep -q "claude: 1 still waiting on you after 0m06s" "$LOG"

reset
hook s1 prompt
CLAUDE_TRANSIT_WAIT_SECS=5 ct 5 >/dev/null
lid Yes; sleep 1.5
hook s1 wait; sleep 2; hook s1 tool
sleep 6
check "answered in time (from the phone): keeps working" not_disarmed
ct off >/dev/null

reset
hook s1 prompt; hook s1 wait
sleep 2.1
out=$(CLAUDE_TRANSIT_WAIT_SECS=5 ct 5 2>&1)
check "arming while a session waits: the note mentions the hold" has "$out" "keeps the Mac awake for"
lid Yes
sleep 3
check "  the hold counts from arming, not from when it started waiting" not_disarmed
check "  and still ends" wait_for 10 disarmed B

reset
hook s1 prompt
out=$(ct 5 --wait 3 2>&1)
check "--wait sets the hold" has "$out" "waiting on you counts as working for up to 3m00s"
check "  status shows it" has "$(ct status)" "waits 3m00s for answers"
check "  so does the ARMED line" grep -q "ARMED .*waits 3m00s for answers" "$LOG"
ct off >/dev/null
ct 5 --wait soon >/dev/null 2>&1; rc=$?
check "--wait rejects non-numbers" all '[ "$rc" = 1 ] && [ "$(sd)" = 0 ]'
out=$(CLAUDE_TRANSIT_WAIT=4 ct 5 2>&1)
check "CLAUDE_TRANSIT_WAIT sets the default" has "$out" "up to 4m00s"
ct off >/dev/null

# ------------------------------------------------------------------ phone
section "Phone notifications"
pushes() { cat "$STUB_STATE/events" 2>/dev/null | grep -c "^push .*$1"; }
reset
hook s1 prompt
CLAUDE_TRANSIT_NTFY=ct-topic CLAUDE_TRANSIT_WAIT_SECS=5 ct 5 >/dev/null
lid Yes; sleep 1.5
hook s1 wait
check "a question with the lid closed: phone notified" wait_for 3 event "push .*Title: Claude is waiting on you"
check "  to the ntfy topic, high priority" all 'event "Priority: high" && event "https://ntfy.sh/ct-topic"'
sleep 2
check "  just once" is "$(pushes 'waiting on you')" 1
check "  hold over: told the Mac is going to sleep" wait_for 10 event "push .*Mac going to sleep.*No answer came"
check "  before it sleeps" wait_for 5 all 'awk "/Mac going to sleep/ { p = NR } /^sleepnow/ { s = NR } END { exit !(p && s && p < s) }" "$STUB_STATE/events"'
check "  and logged" grep -q 'phone: sent "Mac going to sleep"' "$LOG"

reset
hook s1 prompt
CLAUDE_TRANSIT_NTFY=https://ntfy.example.com/t CLAUDE_TRANSIT_WAIT_SECS=30 ct 5 >/dev/null
hook s1 wait
sleep 2.5
check "lid open when the question comes: no notification yet" is "$(pushes 'waiting on you')" 0
lid Yes
check "  sent once the lid closes, to a full ntfy URL" wait_for 3 event "push .*waiting on you.*https://ntfy.example.com/t"
ct off >/dev/null

reset
hook s1 prompt
CLAUDE_TRANSIT_NOTIFY_CMD='printf "%s|%s\n" "$1" "$2" >> "$STUB_STATE/pushes"' ct 5 >/dev/null
lid Yes; hook s1 stop
check "a custom command gets the title and message" wait_for 8 grep -q "^Mac going to sleep|Claude finished" "$STUB_STATE/pushes"

reset
hook s1 prompt
ct 5 >/dev/null
lid Yes; hook s1 stop
wait_for 7 disarmed B
check "nothing set up: nothing sent" no_event "^push"

reset
hook s1 prompt
CLAUDE_TRANSIT_NTFY=ct-topic ct 5 >/dev/null
lid Yes; sleep 1.5; lid No
wait_for 4 disarmed A
check "lid reopened: no phone notification (you're at the Mac)" no_event "^push"

reset
out=$(CLAUDE_TRANSIT_NTFY=ct-topic ct notify-test 2>&1); rc=$?
check "notify-test sends one" all '[ "$rc" = 0 ] && event "push .*claude-transit test"'
check "  and says where" has "$out" "Sent to ntfy (ct-topic)"
out=$(ct notify-test 2>&1); rc=$?
check "notify-test with nothing set up explains" all '[ "$rc" = 1 ] && [[ $out == *"notifications are off"* ]]'
echo down > "$STUB_STATE/net"
CLAUDE_TRANSIT_NTFY=ct-topic ct notify-test >/dev/null 2>&1; rc=$?
check "notify-test reports a failed send" all '[ "$rc" = 1 ] && grep -q "phone: couldn.t send" "$LOG"'

# ------------------------------------------------------------------ status details
section "Status details"
reset
echo '100%; charged; 0:00 remaining' > "$STUB_STATE/batt"
check "battery: charged" has "$(ct status)" "Battery:   100%, charged, 0:00 remaining"
echo '42%; discharging; (no estimate)' > "$STUB_STATE/batt"
check "battery: drops (no estimate)" has "$(ct status)" "Battery:   42%, discharging"
lid ''
out=$(ct 5 2>&1)
check "unreadable lid: warns but still arms" has "$out" "couldn't read the lid state"
ct off >/dev/null
hook s1 prompt; hook s2 prompt; hook s2 wait; hook s3 prompt; hook s3 stop
check "session summary" has "$(ct status)" "Claude:    1 working, 1 waiting on you, 1 idle"
hook x prompt '{"session_id":"h1","cwd":"'"$HOME"'"}'
check "a session in the home folder itself shows as ~" all 'ct status | grep -q "^             ~  "'

echo missing > "$STUB_STATE/sleepdisabled"
check "no SleepDisabled line reads as normal" has "$(ct status)" "Sleep:     normal (SleepDisabled 0)"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" = 0 ]
