// Tests for lib/hooks.js (the settings.json merge). Run: node tests/hooks.test.js
'use strict';

const assert = require('assert');
const fs = require('fs');
const os = require('os');
const path = require('path');
const { execFileSync } = require('child_process');
const h = require('../lib/hooks.js');

const HOOK = '/Users/someone/.local/bin/claude-transit-hook';
let passed = 0;
function test(name, fn) {
  fn();
  passed++;
  console.log('  ok    ' + name);
}
const parse = (s) => JSON.parse(s);

const existing = {
  model: 'opus',
  permissions: { allow: ['Bash(npm test)'], defaultMode: 'auto' },
  hooks: {
    Stop: [{ hooks: [{ type: 'command', command: 'afplay /System/Library/Sounds/Glass.aiff' }] }],
    PreToolUse: [{ matcher: 'Bash', hooks: [{ type: 'command', command: '~/guard.sh' }] }]
  }
};

console.log('hooks.js');

test('install into a missing or empty file adds seven hooks across six events', () => {
  for (const input of [null, '', '  \n']) {
    const out = parse(h.install(input, HOOK));
    assert.deepStrictEqual(Object.keys(out.hooks).sort(),
      ['Notification', 'PostToolUse', 'PreToolUse', 'SessionEnd', 'Stop', 'SubagentStart', 'SubagentStop', 'UserPromptSubmit']);
    assert.strictEqual(h.countOurs(JSON.stringify(out)), 9);
  }
});

test('commands are quoted paths plus the event argument', () => {
  const out = parse(h.install(null, HOOK));
  assert.strictEqual(out.hooks.Stop[0].hooks[0].command, "'" + HOOK + "' stop");
  assert.strictEqual(out.hooks.UserPromptSubmit[0].hooks[0].command, "'" + HOOK + "' prompt");
  assert.strictEqual(out.hooks.Stop[0].hooks[0].timeout, 10);
});

test('Notification: idle_prompt reports idle, questions report wait', () => {
  const out = parse(h.install(null, HOOK));
  const n = out.hooks.Notification;
  assert.strictEqual(n.length, 2);
  assert.strictEqual(n[0].matcher, 'idle_prompt');
  assert.ok(n[0].hooks[0].command.endsWith(' idle'));
  assert.strictEqual(n[1].matcher, 'permission_prompt|elicitation_dialog');
  assert.ok(n[1].hooks[0].command.endsWith(' wait'));
  assert.strictEqual(out.hooks.Stop[0].matcher, undefined);
  assert.ok(out.hooks.PreToolUse[0].hooks[0].command.endsWith(' tool'));
});

test('keeps existing settings and hooks, appending ours after them', () => {
  const out = parse(h.install(JSON.stringify(existing), HOOK));
  assert.strictEqual(out.model, 'opus');
  assert.deepStrictEqual(out.permissions, existing.permissions);
  assert.strictEqual(out.hooks.PreToolUse.length, 2);
  assert.deepStrictEqual(out.hooks.PreToolUse[0], existing.hooks.PreToolUse[0]);
  assert.strictEqual(out.hooks.Stop.length, 2);
  assert.deepStrictEqual(out.hooks.Stop[0], existing.hooks.Stop[0]);
  assert.ok(out.hooks.Stop[1].hooks[0].command.includes('claude-transit-hook'));
});

test('install is idempotent', () => {
  const once = h.install(JSON.stringify(existing), HOOK);
  assert.strictEqual(h.install(once, HOOK), once);
});

test('reinstalling with a new path replaces the old entries', () => {
  const once = h.install(JSON.stringify(existing), '/old/claude-transit-hook');
  const twice = parse(h.install(once, HOOK));
  assert.strictEqual(h.countOurs(JSON.stringify(twice)), 9);
  assert.ok(!JSON.stringify(twice).includes('/old/'));
});

test('uninstall restores the original exactly', () => {
  assert.deepStrictEqual(parse(h.uninstall(h.install(JSON.stringify(existing), HOOK))), existing);
  const noHooks = { model: 'opus' };
  assert.deepStrictEqual(parse(h.uninstall(h.install(JSON.stringify(noHooks), HOOK))), noHooks);
});

test('uninstall keeps handlers that share a group with ours', () => {
  const mixed = { hooks: { Stop: [{ hooks: [
    { type: 'command', command: 'say done' },
    { type: 'command', command: "'" + HOOK + "' stop" }
  ] }] } };
  const out = parse(h.uninstall(JSON.stringify(mixed)));
  assert.deepStrictEqual(out.hooks.Stop, [{ hooks: [{ type: 'command', command: 'say done' }] }]);
});

test('uninstall leaves an unrelated empty hooks object alone', () => {
  assert.deepStrictEqual(parse(h.uninstall('{"hooks":{}}')), { hooks: {} });
});

test('refuses malformed input instead of guessing', () => {
  assert.throws(() => h.install('{not json', HOOK));
  assert.throws(() => h.install('[]', HOOK));
  assert.throws(() => h.install('{"hooks":[]}', HOOK));
  assert.throws(() => h.install('{"hooks":{"Stop":{}}}', HOOK));
  assert.throws(() => h.install('{}', ''));
});

test('shell quoting survives spaces and apostrophes', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "it's a dir "));
  const script = path.join(dir, 'claude-transit-hook');
  fs.writeFileSync(script, '#!/bin/sh\necho "ran $1"\n', { mode: 0o755 });
  const cmd = parse(h.install(null, script)).hooks.Stop[0].hooks[0].command;
  assert.strictEqual(execFileSync('/bin/sh', ['-c', cmd]).toString().trim(), 'ran stop');
  fs.rmSync(dir, { recursive: true });
});

test('JXA entry point, with the ObjC bridge mocked', () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'ct-'));
  const file = path.join(dir, 'settings.json');
  global.ObjC = { import() {}, unwrap: (x) => (x === null ? undefined : x.value) };
  global.$ = {
    NSUTF8StringEncoding: 4,
    NSFileManager: { defaultManager: { fileExistsAtPath: (p) => fs.existsSync(p) } },
    NSString: { stringWithContentsOfFileEncodingError: (p) => ({ value: fs.readFileSync(p, 'utf8') }) }
  };
  const fresh = parse(h.run(['install', file, HOOK]));   // file doesn't exist yet
  assert.strictEqual(h.countOurs(JSON.stringify(fresh)), 9);
  fs.writeFileSync(file, JSON.stringify(existing));
  const merged = h.run(['install', file, HOOK]);
  fs.writeFileSync(file, merged);
  assert.strictEqual(h.run(['verify', file]), '9');
  assert.deepStrictEqual(parse(h.run(['uninstall', file])), existing);
  assert.throws(() => h.run(['verify', path.join(dir, 'missing.json')]));
  assert.throws(() => h.run(['frobnicate', file]));
  fs.rmSync(dir, { recursive: true });
});

console.log('\n' + passed + ' passed');
