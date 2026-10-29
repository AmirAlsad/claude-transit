// Adds or removes claude-transit's hooks in a Claude Code settings.json.
//
//   osascript -l JavaScript hooks.js install   <settings.json> <path to claude-transit-hook>
//   osascript -l JavaScript hooks.js uninstall <settings.json>
//   osascript -l JavaScript hooks.js verify    <file>
//
// install/uninstall print the updated JSON, and install.sh writes the file.
// verify prints how many claude-transit hook handlers a file contains.
// Runs under JXA (built into macOS, so no jq or Node needed). It also loads
// under Node, so the merge logic can be tested off a Mac.

'use strict';

var MARKER = 'claude-transit-hook';

// [hook event, matcher (or null for all), argument for claude-transit-hook]
var ENTRIES = [
  ['UserPromptSubmit', null, 'prompt'],
  ['PreToolUse', null, 'tool'],
  ['PostToolUse', null, 'tool'],
  ['Stop', null, 'stop'],
  ['SubagentStart', null, 'substart'],
  ['SubagentStop', null, 'subend'],
  ['Notification', 'idle_prompt', 'idle'],
  ['Notification', 'permission_prompt|elicitation_dialog', 'wait'],
  ['SessionEnd', null, 'end']
];

function shellQuote(s) {
  return "'" + String(s).replace(/'/g, "'\\''") + "'";
}

function isOurs(handler) {
  return !!handler && typeof handler.command === 'string' &&
    handler.command.indexOf(MARKER) !== -1;
}

function parseSettings(text) {
  if (text === null || text === undefined || /^\s*$/.test(text)) return {};
  var s = JSON.parse(text);
  if (s === null || typeof s !== 'object' || Array.isArray(s)) {
    throw new Error('settings.json is not a JSON object');
  }
  if (s.hooks !== undefined &&
      (s.hooks === null || typeof s.hooks !== 'object' || Array.isArray(s.hooks))) {
    throw new Error('"hooks" in settings.json is not an object');
  }
  return s;
}

// Removes every claude-transit handler, dropping any group or event that
// only held ours. Leaves everything else exactly as it was.
function strip(settings) {
  var hooks = settings.hooks;
  var removed = 0;
  if (!hooks) return 0;
  Object.keys(hooks).forEach(function (event) {
    var groups = hooks[event];
    if (!Array.isArray(groups)) return;
    var kept = [];
    groups.forEach(function (group) {
      if (!group || !Array.isArray(group.hooks)) { kept.push(group); return; }
      var others = group.hooks.filter(function (h) { return !isOurs(h); });
      var n = group.hooks.length - others.length;
      removed += n;
      if (n === 0) { kept.push(group); return; }
      if (others.length > 0) { group.hooks = others; kept.push(group); }
    });
    if (kept.length === 0 && groups.length > 0) delete hooks[event];
    else hooks[event] = kept;
  });
  if (removed > 0 && Object.keys(hooks).length === 0) delete settings.hooks;
  return removed;
}

function install(text, hookPath) {
  if (!hookPath) throw new Error('install needs the path to claude-transit-hook');
  var settings = parseSettings(text);
  strip(settings);
  if (!settings.hooks) settings.hooks = {};
  var cmd = shellQuote(hookPath);
  ENTRIES.forEach(function (e) {
    var event = e[0], matcher = e[1], arg = e[2];
    var list = settings.hooks[event];
    if (list !== undefined && !Array.isArray(list)) {
      throw new Error('hooks.' + event + ' in settings.json is not an array');
    }
    var group = {};
    if (matcher) group.matcher = matcher;
    group.hooks = [{ type: 'command', command: cmd + ' ' + arg, timeout: 10 }];
    settings.hooks[event] = (list || []).concat([group]);
  });
  return JSON.stringify(settings, null, 2);
}

function uninstall(text) {
  var settings = parseSettings(text);
  strip(settings);
  return JSON.stringify(settings, null, 2);
}

function countOurs(text) {
  var settings = parseSettings(text);
  var n = 0;
  Object.keys(settings.hooks || {}).forEach(function (event) {
    var groups = settings.hooks[event];
    if (!Array.isArray(groups)) return;
    groups.forEach(function (g) {
      if (g && Array.isArray(g.hooks)) n += g.hooks.filter(isOurs).length;
    });
  });
  return n;
}

// ---- JXA entry point (osascript calls run and prints what it returns)

function readText(path) {
  if (!$.NSFileManager.defaultManager.fileExistsAtPath(path)) return null;
  var s = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(
    path, $.NSUTF8StringEncoding, null));
  if (typeof s !== 'string') throw new Error('could not read ' + path + ' as UTF-8');
  return s;
}

function run(argv) {
  ObjC.import('Foundation');
  var mode = argv[0], path = argv[1];
  if (!path) throw new Error('usage: hooks.js install|uninstall|verify <file> [hook path]');
  var text = readText(path);
  if (mode === 'install') return install(text, argv[2]);
  if (mode === 'uninstall') return uninstall(text);
  if (mode === 'verify') {
    if (text === null) throw new Error('no such file: ' + path);
    return String(countOurs(text));
  }
  throw new Error('unknown mode: ' + mode);
}

if (typeof module !== 'undefined' && module.exports) {
  module.exports = {
    install: install, uninstall: uninstall, countOurs: countOurs,
    ENTRIES: ENTRIES, shellQuote: shellQuote, run: run
  };
}
