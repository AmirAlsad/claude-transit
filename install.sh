#!/bin/bash
#
# install.sh: set up claude-transit for the current user.
#
#   ./install.sh              install, or update an existing install
#   ./install.sh --uninstall  remove everything install.sh added (keeps the log)
#
# Run it as yourself, not with sudo. It asks for your password once, for the
# sudoers rule. The rule is written for whoever runs this script, so under
# sudo it would be written for root and silently do nothing for you.

set -euo pipefail

SRC=$(cd "$(dirname "$0")" && pwd)
BIN_DIR="$HOME/.local/bin"
HOOK="$BIN_DIR/claude-transit-hook"
SETTINGS="$HOME/.claude/settings.json"
STATE_DIR="$HOME/.local/state/claude-transit"
SUDOERS_DIR="/etc/sudoers.d"
SUDOERS_FILE="$SUDOERS_DIR/claude-transit"
PMSET="/usr/bin/pmset"
ZSHRC="$HOME/.zshrc"
# Absolute path, so it works even if ~/.local/bin is added to PATH later in the file.
# shellcheck disable=SC2016  # $HOME is meant to expand in zsh, not here
ZSHRC_LINE='[ -x "$HOME/.local/bin/claude-transit" ] && "$HOME/.local/bin/claude-transit" check  # added by claude-transit'
AGENT_LABEL="com.claude-transit.login-check"
AGENT_PLIST="$HOME/Library/LaunchAgents/$AGENT_LABEL.plist"

step() { printf '==> %s\n' "$*"; }
note() { printf '    %s\n' "$*"; }
die()  { printf 'install.sh: %s\n' "$*" >&2; exit 1; }

preflight() {
  [ "$(uname -s)" = Darwin ] || die "claude-transit only runs on macOS."
  if [ "$(id -u)" -eq 0 ]; then
    die "run this as yourself, without sudo. It asks for your password when it needs it."
  fi
  USER_NAME=$(id -un)
  case $USER_NAME in
    ''|*[!A-Za-z0-9._-]*) die "unexpected username '$USER_NAME'" ;;
  esac
  local f
  for f in bin/claude-transit bin/claude-transit-hook lib/hooks.js; do
    [ -f "$SRC/$f" ] || die "missing $f. Run install.sh from inside the claude-transit folder."
  done
}

stop_running_guard() {
  if [ -x "$BIN_DIR/claude-transit" ]; then
    "$BIN_DIR/claude-transit" off >/dev/null 2>&1 || true
  fi
}

install_scripts() {
  mkdir -p "$BIN_DIR"
  install -m 0755 "$SRC/bin/claude-transit" "$BIN_DIR/claude-transit"
  install -m 0755 "$SRC/bin/claude-transit-hook" "$HOOK"
  # Files unzipped from a download carry a quarantine flag; clear it on our copies.
  xattr -d com.apple.quarantine "$BIN_DIR/claude-transit" "$HOOK" 2>/dev/null || true
  note "$BIN_DIR/claude-transit"
  note "$HOOK"
}

install_sudoers() {
  local tmp
  [ -d "$SUDOERS_DIR" ] || die "$SUDOERS_DIR doesn't exist, so a drop-in rule can't be added."
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-transit-sudoers.XXXXXX")
  {
    echo "# Added by claude-transit install.sh. Lets $USER_NAME turn lid-closed sleep"
    echo "# off and back on without a password. Remove with: ./install.sh --uninstall"
    echo "$USER_NAME ALL=(root) NOPASSWD: $PMSET -a disablesleep 1, $PMSET -a disablesleep 0"
  } > "$tmp"

  note "sudo will ask for your password to write $SUDOERS_FILE"
  if ! sudo /usr/sbin/visudo -c -q -f "$tmp"; then
    rm -f "$tmp"
    die "the rule didn't pass visudo, so nothing was installed."
  fi
  sudo /usr/bin/install -m 0440 -o root -g wheel "$tmp" "$SUDOERS_FILE"
  rm -f "$tmp"

  # Check sudo's whole config with the rule in place. A broken sudoers file
  # can lock you out of sudo, so back out immediately if anything is off.
  if ! sudo /usr/sbin/visudo -c -q; then
    # If sudo itself is what broke, it can't remove the file either. macOS's
    # own admin prompt doesn't depend on sudo.
    sudo rm -f "$SUDOERS_FILE" 2>/dev/null ||
      osascript -e "do shell script \"rm -f $SUDOERS_FILE\" with administrator privileges" >/dev/null 2>&1 ||
      true
    if [ -e "$SUDOERS_FILE" ]; then
      die "sudo's config didn't validate and the rule couldn't be removed. Remove it with: osascript -e 'do shell script \"rm -f $SUDOERS_FILE\" with administrator privileges'"
    fi
    die "sudo's config didn't validate with the rule in place, so the rule was removed."
  fi

  # Forget the cached password, then prove the rule works without one.
  sudo -k
  if ! sudo -n "$PMSET" -a disablesleep 0 >/dev/null 2>&1; then
    die "the rule is installed but sudo still wants a password for pmset. Check that /etc/sudoers contains '#includedir /private/etc/sudoers.d'."
  fi
  note "ok: pmset runs without a password"
}

# Merge our hooks into (or out of) ~/.claude/settings.json. The JSON work is
# done by lib/hooks.js under JXA, which ships with macOS.
update_settings() {  # install | uninstall
  local mode=$1 tmp count
  if [ "$mode" = uninstall ]; then
    if [ ! -f "$SETTINGS" ]; then note "no $SETTINGS"; return 0; fi
    count=$(osascript -l JavaScript "$SRC/lib/hooks.js" verify "$SETTINGS") ||
      die "couldn't read $SETTINGS; left it unchanged"
    if [ "$count" = 0 ]; then note "no claude-transit hooks in it"; return 0; fi
  fi

  mkdir -p "$(dirname "$SETTINGS")"
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-transit-settings.XXXXXX")
  if ! osascript -l JavaScript "$SRC/lib/hooks.js" "$mode" "$SETTINGS" "$HOOK" > "$tmp"; then
    rm -f "$tmp"
    die "couldn't update $SETTINGS; left it unchanged"
  fi

  # Read the result back before it replaces anything.
  if ! count=$(osascript -l JavaScript "$SRC/lib/hooks.js" verify "$tmp"); then
    rm -f "$tmp"
    die "the updated settings didn't read back cleanly; left $SETTINGS unchanged"
  fi
  if { [ "$mode" = install ] && [ "$count" = 0 ]; } || { [ "$mode" = uninstall ] && [ "$count" != 0 ]; }; then
    rm -f "$tmp"
    die "the updated settings don't look right ($count hooks); left $SETTINGS unchanged"
  fi

  if [ -f "$SETTINGS" ] && cmp -s "$tmp" "$SETTINGS"; then
    rm -f "$tmp"
    note "already up to date"
    return 0
  fi
  if [ -f "$SETTINGS" ]; then
    cp -p "$SETTINGS" "$SETTINGS.claude-transit-backup"
    note "backup of the previous file: $SETTINGS.claude-transit-backup"
  fi
  # Write through rather than mv, so a symlinked settings.json keeps its link.
  cat "$tmp" > "$SETTINGS"
  rm -f "$tmp"
  note "updated $SETTINGS"
}

# At each login, restore sleep if it was left off with no guard running (for
# example, the battery died while armed). It runs once and exits; nothing
# stays in the background.
install_login_agent() {
  mkdir -p "$(dirname "$AGENT_PLIST")"
  cat > "$AGENT_PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$AGENT_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$BIN_DIR/claude-transit</string>
    <string>check</string>
    <string>--fix</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
</dict>
</plist>
PLIST
  plutil -lint "$AGENT_PLIST" >/dev/null || die "the login check's plist didn't validate: $AGENT_PLIST"
  note "$AGENT_PLIST"
  note "(macOS may show a \"Background Items Added\" notice for it)"
}

remove_login_agent() {
  launchctl bootout "gui/$(id -u)/$AGENT_LABEL" >/dev/null 2>&1 || true
  if [ -e "$AGENT_PLIST" ]; then
    rm -f "$AGENT_PLIST"
    note "removed $AGENT_PLIST"
  else
    note "not installed"
  fi
}

offer_zshrc_check() {
  if grep -qF -e 'claude-transit check' -e '# added by claude-transit' "$ZSHRC" 2>/dev/null; then
    return 0
  fi
  echo
  echo "If the watcher is killed outright (kill -9), its guardian turns sleep back on. If both"
  echo "are killed, nothing does until your next login. A one-line check in ~/.zshrc warns you"
  echo "about that in every new terminal."
  if [ -t 0 ]; then
    local ans=''
    read -r -p "Add it to ~/.zshrc? [Y/n] " ans || true
    case $ans in
      [nN]*) note "skipped. To add it later: echo '$ZSHRC_LINE' >> ~/.zshrc" ;;
      *) printf '\n%s\n' "$ZSHRC_LINE" >> "$ZSHRC"; note "added to ~/.zshrc" ;;
    esac
  else
    note "to add it: echo '$ZSHRC_LINE' >> ~/.zshrc"
  fi
}

remove_zshrc_check() {
  local tmp
  grep -qF '# added by claude-transit' "$ZSHRC" 2>/dev/null || return 0
  tmp=$(mktemp "${TMPDIR:-/tmp}/claude-transit-zshrc.XXXXXX")
  grep -vF '# added by claude-transit' "$ZSHRC" > "$tmp" || true
  cat "$tmp" > "$ZSHRC"
  rm -f "$tmp"
  note "removed the check line from ~/.zshrc"
}

do_install() {
  # Check settings.json parses before changing anything, so a bad file
  # doesn't leave a half-finished install behind.
  if [ -f "$SETTINGS" ] && ! osascript -l JavaScript "$SRC/lib/hooks.js" verify "$SETTINGS" >/dev/null; then
    die "$SETTINGS isn't valid JSON (see the error above). Fix it and run install.sh again."
  fi

  step "Installing scripts"
  stop_running_guard
  install_scripts

  step "Adding the sudoers rule"
  install_sudoers

  step "Adding Claude Code hooks"
  update_settings install

  step "Adding a login check"
  install_login_agent

  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo
      echo "$BIN_DIR isn't on your PATH. Add it with:"
      echo "  echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ~/.zshrc"
      ;;
  esac

  offer_zshrc_check

  echo
  step "Done. Current state:"
  "$BIN_DIR/claude-transit" status | sed 's/^/    /' || true
  echo
  echo "Claude Code sessions that are already open usually pick up the new hooks on their own."
  echo "If 'claude-transit status' doesn't count a session after you send it a prompt,"
  echo "restart that session."
  echo
  echo "Optional: to get phone notifications when a session waits on you with the lid closed,"
  echo "see \"Phone notifications\" in the README, then run: claude-transit notify-test"
}

do_uninstall() {
  step "Stopping any running guard"
  stop_running_guard

  step "Removing Claude Code hooks"
  update_settings uninstall

  step "Removing the sudoers rule"
  if [ -e "$SUDOERS_FILE" ]; then
    sudo rm -f "$SUDOERS_FILE"
    note "removed $SUDOERS_FILE"
  else
    note "not installed"
  fi

  step "Removing the login check"
  remove_login_agent

  step "Removing scripts and state"
  rm -f "$BIN_DIR/claude-transit" "$HOOK"
  rm -rf "$STATE_DIR"
  remove_zshrc_check
  note "kept the log: ~/Library/Logs/claude-transit.log"
}

case "${1:-}" in
  ''|--install) preflight; do_install ;;
  --uninstall)  preflight; do_uninstall ;;
  -h|--help)    sed -n '3,10p' "$0" | sed 's/^# \{0,1\}//' ;;
  *)            die "unknown option '$1' (try --help)" ;;
esac
