# claude-transit

Keeps a MacBook awake with the lid closed while Claude Code is working, so you
can walk between places without the session stalling. It hands control back to
normal sleep as soon as there's nothing left to protect.

```
claude-transit            # arm for 30 minutes (default)
claude-transit 45         # arm for 45 minutes (max 240)
claude-transit --no-early # arm, but ignore "Claude finished" (see below)
claude-transit --wait 15  # stay awake up to 15 min for a question you haven't answered (default 10)
claude-transit status     # guard, sleep, lid, Claude sessions, battery
claude-transit off        # disarm now
claude-transit log        # recent log lines
claude-transit notify-test  # check that phone notifications arrive
```

Typical trip: start the task in Claude Code, join your hotspot, run
`claude-transit`, close the lid, walk, open the lid. If Claude stops to ask
you something on the way, answer it from your phone with
[Remote Control](https://code.claude.com/docs/en/remote-control): the Mac
stays awake for a while so the answer can land.

When you arm it, it lists every Claude Code session by project folder and
prints three reminders: battery level, how to carry the Mac so it can shed
heat, and joining the hotspot first.

## Requirements

- A MacBook running macOS. It uses only tools that ship with macOS (bash 3.2,
  `pmset`, `ioreg`, `osascript`, `curl`), so there's nothing else to install.
- Claude Code, signed in. Answering prompts from your phone needs
  [Remote Control](https://code.claude.com/docs/en/remote-control) and the
  Claude app. Last checked with Claude Code 2.1.312.
- An admin account, for the one-time sudoers rule.

## Install

```
git clone https://github.com/AmirAlsad/claude-transit.git
cd claude-transit
./install.sh          # or: bash install.sh
```

Run it as yourself, not with `sudo`. It asks for your password once. It makes
four changes:

1. **Scripts.** Copies `claude-transit` and `claude-transit-hook` to `~/.local/bin`.
2. **Sudoers rule.** Adds `/etc/sudoers.d/claude-transit`, which allows exactly two commands without a password:
   ```
   <you> ALL=(root) NOPASSWD: /usr/bin/pmset -a disablesleep 1, /usr/bin/pmset -a disablesleep 0
   ```
   The rule is checked with `visudo` before and after install, and removed again if anything fails.
3. **Claude Code hooks.** Adds nine hook entries to `~/.claude/settings.json`. Your other settings and hooks stay as they are, and the previous file is saved as `settings.json.claude-transit-backup`.
4. **Login check.** Adds `~/Library/LaunchAgents/com.claude-transit.login-check.plist`. At each login it runs `claude-transit check --fix` once and exits; nothing stays running. macOS may show a "Background Items Added" notice for it.

It also offers to add two lines to `~/.zshrc`, each marked
`# added by claude-transit`. One warns you if sleep is ever left off (see "If
something goes wrong"). The other sets up [phone notifications](#phone-notifications).
Both are optional.

**Updating:** `git pull`, then `./install.sh` again. It replaces the scripts
and hooks in place and leaves your settings alone.

**Uninstalling:** `./install.sh --uninstall` reverses all of it, including the
`~/.zshrc` lines it added. It keeps only the log.

## Quick start

1. **Check the install.** `claude-transit status` should say `Hooks: installed`
   and `Sudo rule: installed`. Then run the [hardware checklist](#full-checklist)
   once. It takes about 20 minutes and is the only test that touches your real
   Mac.
2. **Set up your phone,** so you can answer Claude while the lid is shut:
   - Install the Claude app ([iOS](https://apps.apple.com/us/app/claude-by-anthropic/id6473753684),
     [Android](https://play.google.com/store/apps/details?id=com.anthropic.claude))
     and sign in with the same account as Claude Code.
   - In Claude Code, run `/config` and turn on **Enable Remote Control for all
     sessions**, or run `/remote-control` in a session before you leave.
   - In `/config`, turn on **Push when actions required**.
   - Optional: [claude-transit's own notifications](#phone-notifications), as a
     backstop and to hear when the Mac goes to sleep.
3. **On a trip:** start the task, join your hotspot, run `claude-transit`, and
   close the lid. If your phone says Claude is waiting on you, answer in the
   Claude app. Open the lid when you arrive.
4. **Make it yours.** Every timing and the notification setup can be changed;
   see [Configuration](#configuration).


## When sleep comes back

While the guard is armed, a background watcher checks every 3 seconds. It
restores normal sleep on the first of these:

| | Trigger | What happens |
|---|---|---|
| **A** | You open the lid after closing it | Sleep restored, notification shown |
| **B** | Lid closed, and no Claude Code session has been working for 30s. A session waiting on you counts as working for up to 10 min | Sleep restored, Mac put to sleep now |
| **H** | macOS reports critical heat | Sleep restored; Mac put to sleep now if the lid is closed, otherwise a notification |
| **C** | Time is up (30 min by default) | Sleep restored; if the lid is closed, Mac put to sleep now |

`off`, a crash of the watcher, or `kill` also restore sleep.

**The guardian.** `kill -9` can't be caught: the kernel removes the process
without telling it, so no cleanup code runs. Any cleanup has to come from
another process. Arming therefore starts a small guardian that starts the
watcher and waits on it. If the watcher exits and sleep is still off, the
guardian turns it back on, puts the Mac to sleep if the lid is closed, and
logs a `GUARDIAN:` line. It exits with the watcher. `off` and re-arming stop
the guardian first, so a deliberate stop doesn't look like a crash.

### How it knows Claude is working

Each Claude Code session reports its own state through hooks:

| Hook | Reports |
|---|---|
| `UserPromptSubmit`, `PreToolUse`, `PostToolUse` | working |
| `Stop`, `Notification: idle_prompt` (waiting for input for 60s) | idle |
| `Notification: permission_prompt`, `elicitation_dialog` (MCP question) | waiting on you |
| `SubagentStart`, `SubagentStop` | a subagent started or finished |
| `SessionEnd` | gone |

**Subagents count separately.** Claude often hands work to a background
subagent and ends its own turn. Hooks fired inside a subagent carry its ID, so
each subagent gets its own report, and the session counts as working until the
last one sends `SubagentStop`. If a subagent's hooks go quiet for 10 minutes
(for example, it was stopped in a way that skipped `SubagentStop`), it stops
counting. A subagent's long command still counts through the command check
below. Change the 10 minutes with `CLAUDE_TRANSIT_AGENT_QUIET` (in seconds).

**Commands Claude started count as working.** Claude often runs long things
like test suites, builds or sleeps as background commands and ends its turn.
The watcher also checks whether each session's Claude process still has one
of its commands running, and if so the session counts as working. When the
command finishes, Claude wakes up, replies and stops, and the Mac sleeps 30s
later. Arming and `status` list those commands with a `$`:

```
Claude: 1 running a command
  ~/code/webapp                  running a command
      $ npm test
```

A command that never exits, like a dev server or a file watcher, keeps the Mac
awake until you open the lid or the time runs out. That's why arming lists
them. One exception: a bare `tail -f` doesn't count. Claude Code's Monitor
tool uses one to follow a background task's output, and the task it follows
is counted on its own. The log records when commands start and stop keeping it awake
(`commands running: npm test`, later `commands running: none`).

Labels hide anything that might be a secret, because they go into the log.
Variables set at the start of a command show their name only
(`export TOKEN="abc" && npm test` appears as `TOKEN=… npm test`), and any
long run of letters and digits, like an API key or a UUID, appears as `…`.
A leading `cd <folder> &&` is dropped, and your home folder shows as `~`.

How commands are recognized: Claude Code runs each shell command in a shell
that first loads a snapshot of your environment, so the command line contains
`/.claude/shell-snapshots/`. That's how Claude Code works today, not a
documented interface. If a future version changes it, background commands
stop counting and the Mac can sleep early again, the same as without this
feature. To check it still works, start a background command in Claude and
look for its `$` line in `claude-transit status`. To adapt without editing the
script, set `CLAUDE_TRANSIT_CMD_MARKER` to the new marker.

With several sessions open, B waits until **every** session has stopped
working. An idle session in another tab doesn't hold the Mac awake; a working
one does, even if it isn't the task you care about.

Each report also records the Claude Code process ID. If that process dies
mid-turn (for example, you closed its terminal), its "working" report is
ignored rather than keeping the Mac awake.

**Why hooks instead of CPU usage:** the earlier plan inferred "working" from
the CPU use of processes named `claude`. That reads a long model turn as idle,
because the process is just waiting on the network. It also misses builds and
tests, because those run as `xcodebuild`, `swift`, `npm` and so on. Hooks
report the event itself, so no threshold needs tuning.

**Why a 30s grace period:** a turn can end and pick up again straight away,
for example when a background task finishes. The grace period lets those
restarts cancel the countdown. Change it with `CLAUDE_TRANSIT_GRACE=60 claude-transit`.

**Why "sleep now":** switching `disablesleep` back to 0 with the lid already
closed may not put the Mac to sleep by itself. It could otherwise sit awake in
your bag until the idle timer runs out, so after B, H or C the watcher also runs
`pmset sleepnow`.

## Waiting on you

A session stopped at a permission prompt or a question can't move until
someone answers. With Remote Control, that someone can be you, on your phone.
So a waiting session counts as working for up to 10 minutes, measured from
when it started waiting or from when you armed, whichever is later. Answer in
time and it carries on. If no answer comes, the Mac sleeps 30s after the hold
ends, and the session picks up when you open the lid. The log shows both:

```
... ~/code/my-app is waiting on you; staying awake up to 10m00s for an answer
... claude: 1 still waiting on you after 10m00s
```

Change the hold with `--wait 15`, or for every trip with
`export CLAUDE_TRANSIT_WAIT=15` in `~/.zshrc`. `--wait 0` turns it off, so a
waiting session no longer keeps the Mac awake at all.

Claude Code has no hook for "permission granted". After you approve, the
session reads "waiting" until the approved tool finishes. A shell command
counts as running while it runs, so that's covered. A long tool that isn't a
shell command (a web fetch, an MCP call) is covered only until the hold ends.

## Phone notifications

The hold only helps if you know a question came in. There are two sources of
notifications, and they work well together.

**Claude's own push** (set this up first). In Claude Code, run `/config` and
turn on **Push when actions required**. The Claude app then tells you about
permission prompts and questions in Remote Control sessions.

**claude-transit's notifications** are a backstop in case Claude's push
doesn't arrive, and they're the only way to hear that the Mac is going to
sleep. With the lid closed, claude-transit sends one when:

- a session starts waiting on you (high priority, with the minutes left), and
- it puts the Mac to sleep (Claude finished, no answer came, time ran out, or heat).

Nothing is sent while the lid is open, since you're at the Mac. `install.sh`
offers to set up ntfy for you. To do it by hand, add one of these to
`~/.zshrc`:

```
# ntfy.sh (free, no account): install the ntfy app and subscribe to the same topic
export CLAUDE_TRANSIT_NTFY=claude-transit-k3v9q2x7   # or a full URL to your own ntfy server

# or any command; it gets the title as $1 and the message as $2. For example, Pushover:
export CLAUDE_TRANSIT_NOTIFY_CMD='curl -s -F token=YOUR_APP_TOKEN -F user=YOUR_USER_KEY -F title="$1" -F message="$2" https://api.pushover.net/1/messages.json'
```

Then open a new terminal and run `claude-transit notify-test`. Tapping an ntfy
notification opens claude.ai/code, where your Remote Control sessions are
listed. Messages name only the project folder. Anyone who knows an ntfy.sh
topic name can read it and send to it, so pick one nobody would guess. Each
send is logged (`phone: sent "..."`, or `couldn't send` if the network was
down). A custom command should finish within a few seconds, because the last
notification goes out just before the Mac sleeps.

## What it logs

### Network

Every 15 seconds while armed, the watcher checks whether `api.anthropic.com`
answers, and which network the Mac is on. An iPhone hotspot is recognized by
its `172.20.10.x` address. Other Wi-Fi shows its name when macOS shares it,
and otherwise its address. Each change goes in the log with the lid state and
how long the guard has been armed. The disarm line sums up the trip:

```
... network: iPhone hotspot, online | lid open | armed 0m01s
... network: iPhone hotspot, api.anthropic.com unreachable | lid closed | armed 4m12s
... network: iPhone hotspot, online | lid closed | armed 4m57s | back after about 0m45s
... DISARMED [A] lid reopened | ... | network: 1 drop(s), offline about 0m45s in all, longest 0m45s (iPhone hotspot)
```

Times are accurate to about 15 seconds. To compare trips with and without the
hotspot: `grep -E 'ARMED|network|DISARMED' ~/Library/Logs/claude-transit.log`.

### Trip summary

When a trip ends and the lid was closed at some point, the log gets one `TRIP`
line covering the time the lid was shut:

```
TRIP lid closed 9m23s | Claude: 23 tool calls (Bash 12, Edit 8, Read 3), 2 turns finished, 1 session
     | commands: xcodebuild -scheme MyApp … used 4m10s CPU, finished by 12:01; npm run dev used 0m02s CPU, still running
     | heat peak fair | battery 60% -> 58% | network: no drops (iPhone hotspot)
```

(It's one line in the log; it's wrapped here.)

- **Claude:** tool calls, finished turns and finished subagents while the lid was shut, with the most-used tools. While a guard is armed, the hooks note each event in `~/.local/state/claude-transit/activity`, and the file is deleted when the trip ends. This shows Claude's actions, not its thinking between them.
- **Commands:** the CPU time each command used during the trip, including everything it started, and whether it finished. A build or test run that did real work shows minutes of CPU. A dev server that just sat there shows a few seconds, which tells you the Mac stayed awake for nothing.
- **Heat peak, battery used and network drops** for the same trip.

To see just the summaries: `grep TRIP ~/Library/Logs/claude-transit.log`.

### Heat

Every 15 seconds while armed, the watcher reads macOS's thermal state, the same
reading the system uses when it slows itself down. There are four levels:
nominal, fair, serious and critical. Only critical triggers H. Every change
between levels goes in the log with the lid state and how long the guard has
been armed:

```
2026-09-24 08:41:12 watch[4242] ARMED for 30 min | ... | heat nominal | battery 91%, discharging
2026-09-24 08:49:57 watch[4242] heat fair (was nominal) | lid closed | armed 8m45s
2026-09-24 08:58:03 watch[4242] heat nominal (was fair) | lid closed | armed 16m51s
```

To see how a trip went: `grep -E 'ARMED|heat|DISARMED' ~/Library/Logs/claude-transit.log`.

## Configuration

Settings are environment variables, read each time you arm. Put the ones you
want in `~/.zshrc` (or `~/.bash_profile` if you use bash), then open a new
terminal. One-offs work too: `CLAUDE_TRANSIT_GRACE=60 claude-transit`.

| Variable | Default | What it does |
|---|---|---|
| `CLAUDE_TRANSIT_WAIT` | `10` | Minutes a session waiting on you keeps the Mac awake. `0` turns the hold off. `--wait` overrides it for one trip. |
| `CLAUDE_TRANSIT_NTFY` | off | ntfy.sh topic, or a full ntfy URL, for [phone notifications](#phone-notifications). |
| `CLAUDE_TRANSIT_NOTIFY_CMD` | off | Command for phone notifications; gets the title as `$1` and the message as `$2`. |
| `CLAUDE_TRANSIT_GRACE` | `30` | Seconds with nothing working, lid closed, before the Mac sleeps (trigger B). |
| `CLAUDE_TRANSIT_AGENT_QUIET` | `600` | Seconds a subagent can go without a hook event before it stops counting as working. |
| `CLAUDE_TRANSIT_CMD_MARKER` | `/.claude/shell-snapshots/` | Text that marks a shell command Claude started. Change it only if a Claude Code update breaks command detection. |
| `CLAUDE_TRANSIT_INTERVAL` | `3` | Seconds between checks while armed. |
| `CLAUDE_TRANSIT_HEAT_EVERY`, `CLAUDE_TRANSIT_NET_EVERY` | `15` | Seconds between heat readings, and between network checks. |
| `CLAUDE_TRANSIT_LOG` | `~/Library/Logs/claude-transit.log` | Where the log goes. |

The trip length is an argument, not a setting: `claude-transit 45` arms for 45
minutes (1 to 240). To change your default, use an alias, such as
`alias transit='claude-transit 45 --wait 15'`.

## Things to know

- **Background subagents** count until they send `SubagentStop`, or until their hooks have been quiet for 10 minutes. If one thinks for longer than that without using a tool, use `--no-early`. Only the lid and the timer apply then.
- **A turn that dies from a network error** (for example, the hotspot drops) doesn't fire `Stop`. About a minute later, Claude Code's `idle_prompt` notification should mark it idle, and the Mac sleeps 30s after that. If the notification doesn't come, opening the lid or the timer covers it. Afterwards, send "Continue" as usual.
- **Sleep is off system-wide while armed**, on AC as well as battery. `disablesleep` is a system-wide setting, so the rule uses `-a` rather than `-b` to say what it actually does.
- **Sessions already open when you install** usually pick up the hooks by themselves. If `claude-transit status` doesn't count a session after you send it a prompt, restart that session.
- **Heat.** Don't carry it in a sealed sleeve, padded laptop pocket or packed bag while armed. Arming prints this reminder.
- **The hooks cost little.** A tiny shell script runs before and after each tool call. When nothing has changed, it reads one small file and exits within a few milliseconds.
- **Cloud sessions.** When a task doesn't need your Mac's tools, running it as a cloud session avoids the problem entirely.

## If something goes wrong

- `claude-transit log` shows every arm and disarm. Each entry includes which trigger fired, the lid state, what Claude was doing and the battery level.
- `claude-transit status` shows each session and the process ID it reported.
- `claude-transit off` always restores normal sleep, with or without a guard running.
- Sleep can stay off in two cases:
  - **Both the watcher and its guardian are killed with `kill -9`.** The `~/.zshrc` line prints a warning in every new terminal until you run `claude-transit off`. If only the watcher is killed, the guardian restores sleep on its own.
  - **The Mac shuts down while armed**, for example because the battery died in your bag. The setting may survive a restart, so the login check turns sleep back on and shows a notification.

## Test it on your Mac

### Without spending tokens

Claude Code reports to claude-transit by running `claude-transit-hook`, and
you can run it yourself to fake a session. This one works for 90 seconds and
then finishes:

```
fake() { printf '{"session_id":"manual-test","cwd":"%s"}' "$PWD" | ~/.local/bin/claude-transit-hook "$1"; }
fake prompt                    # fake session starts "working"
(sleep 90; fake stop) &        # ...and "finishes" 90s from now
claude-transit 5
```

Close the lid right away and open it about 3 minutes later. `claude-transit
log` should show the lid closing, `claude: ... idle` around the 90-second mark,
then `DISARMED [B]` 30s after that. Clean up with `fake end`.

To check that background commands are recognized, ask Claude to run something
slow in the background, for example *"run `sleep 120` as a background
command"*. While it runs, `claude-transit status` should list it under that
session with a `$`.

### Full checklist

The automated tests use stand-ins for `pmset` and `ioreg`, so these checks are
the ones that cover the real hardware. Run them once after installing.

1. **Password-free pmset.** Run `sudo -k; sudo -n /usr/bin/pmset -a disablesleep 0 && echo ok`. It should print `ok` without asking for a password.
2. **Hooks report in.** This is the most important check.
   - In Claude Code, `/hooks` should list the claude-transit entries.
   - Ask a session to "run `sleep 20` in bash, then say hi". While it runs, `claude-transit status` in another tab should show `1 working`. The pid should belong to the Claude Code process, and it should still be running. `ps -p <pid> -o command=` shows what it is.
   - After it finishes, the same session should show as `idle`.
   - If the pid belongs to a process that has already exited, early finish would fire in the middle of work. Stop here and open an issue with the status output.
3. **Arm.** Run `claude-transit 2`. `pmset -g | grep SleepDisabled` should show `1`. The `ARMED` line in `claude-transit log` should say `heat nominal` (or fair, serious or critical). If it says `heat unknown`, the heat reading doesn't work on your Mac, so H can't fire. Please open an issue.
4. **A, lid reopened.** Close the lid for 10s, then open it. You should get a notification, `claude-transit log` should show `DISARMED [A]`, and `SleepDisabled` should read `0`.
5. **B, must not sleep while working.** Ask Claude to "run `sleep 150` in bash, then run `date` and tell me the time". Arm, close the lid, and open it after about 4 minutes.
   - The `date` Claude reports should fall inside the time the lid was closed.
   - The log should show `claude: 1 idle` after that point, then `DISARMED [B]` about 30s later.
6. **B, the Mac actually sleeps.** Run `pmset -g log | grep -E "Entering Sleep|Wake from" | tail -3`. It should show a sleep within seconds of the `[B]` line. If the log says `sleepnow: refused`, please open an issue.
7. **Waiting on you.** Ask Claude to do something that needs your permission, and leave the prompt unanswered. Run `claude-transit 15 --wait 2`, close the lid, and open it after about 3 minutes. The log should show `is waiting on you; staying awake up to 2m00s`, then `still waiting on you after 2m00s`, then `DISARMED [B]` about 30s later. With notifications set up, your phone should have one notification for the question and one for the sleep.
8. **C, timeout.** Run `claude-transit 1 --no-early`, close the lid, and wait 2 minutes. The log should show `DISARMED [C]` about 60s after arming, followed by a sleep entry in `pmset -g log`.
9. **Closing the terminal.** Arm, close the terminal window, and open a new one. `claude-transit status` should still say armed. Then run `claude-transit off`.
10. **Guardian.** Arm, and check that `claude-transit status` shows a `Guardian:` pid. Run `kill -9` on the **Guard** pid (the watcher). Within a couple of seconds, `pmset -g | grep SleepDisabled` should read `0`, and the log should have a `GUARDIAN:` line.
11. **Login check (optional, needs a restart).** Arm, then `kill -9` the guardian first and the watcher second, so sleep stays off. A new terminal tab should print the `.zshrc` warning. Restart the Mac. After you log in, you should get a "Sleep had been left off" notification, and `SleepDisabled` should read `0`. If there's no notification and it already reads `0`, the setting doesn't survive a restart on your Mac, which is also fine.

## Files

| Path | What |
|---|---|
| `~/.local/bin/claude-transit` | the command |
| `~/.local/bin/claude-transit-hook` | called by Claude Code hooks |
| `~/.local/state/claude-transit/` | session reports and the watcher's pid file |
| `~/Library/Logs/claude-transit.log` | the log (also visible in Console.app) |
| `/etc/sudoers.d/claude-transit` | the sudoers rule |
| `~/Library/LaunchAgents/com.claude-transit.login-check.plist` | the login check |
| `~/.zshrc` | optional lines marked `# added by claude-transit` |

## Development

```
tests/run.sh /bin/bash      # 193 scenario tests against stub pmset/ioreg/sudo (a few minutes)
node tests/hooks.test.js    # settings.json merge tests
```

The scripts target the bash 3.2 that ships with macOS, so avoid bash 4+
features. The scenario tests run against stand-ins in `tests/stubs`, so they
never touch your real power settings. Last full run: Apple's bash 3.2.57. Issues
and pull requests are welcome; please run both test suites first.
