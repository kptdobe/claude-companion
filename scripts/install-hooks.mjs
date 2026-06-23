#!/usr/bin/env node
/**
 * install-hooks.mjs — wire Claude Code hooks into ~/.claude/settings.json so the
 * companion app learns when each session is thinking / waiting / done.
 *
 * Usage:
 *   node scripts/install-hooks.mjs            # dry-run: show what would change
 *   node scripts/install-hooks.mjs -x         # execute: back up + write settings
 *   node scripts/install-hooks.mjs -r -x      # remove the companion hooks
 *   node scripts/install-hooks.mjs -s <path>  # use a different settings.json
 *
 * Defaults to a DRY RUN. Nothing is written without -x.
 */
import { readFileSync, writeFileSync, existsSync, copyFileSync, chmodSync } from 'node:fs';
import { resolve, dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { homedir } from 'node:os';

const HERE = dirname(fileURLToPath(import.meta.url));
const HOOK_TAG = 'claude-companion-hook';

// Hook event -> state argument passed to the hook script.
// Events listed under `matcherEvents` need a { matcher, hooks } wrapper.
const EVENT_STATE = {
  UserPromptSubmit: 'thinking',
  PreToolUse: 'thinking',
  PostToolUse: 'thinking',
  PreCompact: 'thinking',
  // A subagent finishing doesn't end the main turn — keep it "thinking".
  SubagentStop: 'thinking',
  Notification: 'waiting',
  // `Stop` = the turn ended and Claude needs you. This is the attention state.
  Stop: 'waiting',
  SessionEnd: 'idle',
};
const MATCHER_EVENTS = new Set(['PreToolUse', 'PostToolUse', 'PreCompact']);

function parseArgs(argv) {
  const args = { execute: false, remove: false, settings: null, hook: null };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === '-x' || a === '--execute') args.execute = true;
    else if (a === '-r' || a === '--remove') args.remove = true;
    else if (a === '-s' || a === '--settings') args.settings = argv[++i];
    else if (a === '-h' || a === '--hook') args.hook = argv[++i];
    else throw new Error(`Unknown argument: ${a}`);
  }
  return args;
}

/** Strip any existing companion hook entries from a settings object (idempotent). */
function stripCompanionHooks(hooks) {
  const cleaned = {};
  for (const [event, entries] of Object.entries(hooks)) {
    const kept = entries
      .map((entry) => ({
        ...entry,
        hooks: (entry.hooks || []).filter(
          (h) => !(h.command || '').includes(HOOK_TAG),
        ),
      }))
      .filter((entry) => (entry.hooks || []).length > 0);
    if (kept.length > 0) cleaned[event] = kept;
  }
  return cleaned;
}

/** Add a companion hook entry for one event to the hooks object. */
function addHook(hooks, event, command) {
  const hookDef = { type: 'command', command };
  const entry = MATCHER_EVENTS.has(event)
    ? { matcher: '', hooks: [hookDef] }
    : { hooks: [hookDef] };
  hooks[event] = [...(hooks[event] || []), entry];
}

function buildHooks(existing, hookPath, remove) {
  const hooks = stripCompanionHooks(existing || {});
  if (remove) return hooks;
  for (const [event, state] of Object.entries(EVENT_STATE)) {
    addHook(hooks, event, `${hookPath} ${state}`);
  }
  return hooks;
}

function main() {
  const args = parseArgs(process.argv);
  const settingsPath = resolve(
    args.settings || join(homedir(), '.claude', 'settings.json'),
  );
  const hookPath = resolve(args.hook || join(HERE, 'claude-companion-hook'));

  if (!existsSync(hookPath)) {
    throw new Error(`Hook script not found: ${hookPath}`);
  }

  const settings = existsSync(settingsPath)
    ? JSON.parse(readFileSync(settingsPath, 'utf8'))
    : {};
  settings.hooks = buildHooks(settings.hooks, hookPath, args.remove);

  const rendered = JSON.stringify(settings, null, 2);

  console.log(`Settings file : ${settingsPath}`);
  console.log(`Hook script   : ${hookPath}`);
  console.log(`Action        : ${args.remove ? 'REMOVE companion hooks' : 'INSTALL companion hooks'}`);
  console.log('--- resulting "hooks" block ---');
  console.log(JSON.stringify(settings.hooks, null, 2));

  if (!args.execute) {
    console.log('\nDRY RUN — nothing written. Re-run with -x to apply.');
    return;
  }

  if (existsSync(settingsPath)) {
    const backup = `${settingsPath}.companion-bak-${Date.now()}`;
    copyFileSync(settingsPath, backup);
    console.log(`\nBacked up existing settings to: ${backup}`);
  }
  writeFileSync(settingsPath, `${rendered}\n`);
  try { chmodSync(hookPath, 0o755); } catch { /* best effort */ }
  console.log(`Wrote ${settingsPath}`);
  console.log('Restart any running Claude Code sessions to pick up the hooks.');
}

main();
