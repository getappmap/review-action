#!/usr/bin/env node
// Usage accounting for the review action. Everything reported comes directly
// from the agent's own output — nothing is estimated or priced from tables.
// Claude Code reports cost in USD; the Copilot CLI reports premium requests
// (its billing unit) and no dollar figure, so none is shown for it.
//
// Subcommands:
//   stream <claude|copilot> --raw-out <file>
//       Reads the agent's JSONL event stream on stdin, tees every line to
//       --raw-out, and prints a compact live progress line per meaningful
//       event (tool calls, assistant messages) so the CI log shows what the
//       agent is doing during a long run.
//   normalize claude  <raw.json|raw.jsonl>  --mode <update|review> --out <file>
//   normalize copilot <raw-stream.jsonl>    --mode <update|review> --out <file> [--state-dir <dir>]
//       Writes the normalized usage record to --out and prints the agent's
//       final message(s) to stdout (suppress with --no-log when `stream`
//       already showed them live).
//   report
//       Aggregates $USAGE_DIR/usage-*.json into a Markdown footer
//       ($USAGE_DIR/usage-footer.md) and $GITHUB_OUTPUT step outputs.

import { readFileSync, writeFileSync, existsSync, readdirSync, appendFileSync, createWriteStream } from 'node:fs';
import { join } from 'node:path';
import { createInterface } from 'node:readline';

function fail(message) {
  console.error(`usage.mjs: ${message}`);
  process.exit(2);
}

function parseFlags(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      const key = argv[i].slice(2);
      const next = argv[i + 1];
      if (next === undefined || next.startsWith('--')) flags[key] = true; // boolean flag
      else flags[key] = argv[++i];
    } else {
      positional.push(argv[i]);
    }
  }
  return { flags, positional };
}

// ---------------------------------------------------------------------------
// stream
// ---------------------------------------------------------------------------

function truncate(s, n = 160) {
  const flat = String(s).replace(/\s+/g, ' ').trim();
  return flat.length > n ? `${flat.slice(0, n)}…` : flat;
}

function toolSummary(input) {
  if (!input || typeof input !== 'object') return '';
  const detail = input.command ?? input.file_path ?? input.pattern ?? input.description ?? input.prompt;
  return truncate(detail ?? JSON.stringify(input), 140);
}

// The progress vocabulary, per agent. Deliberately sparse: tool calls and
// assistant messages are the narrative; thinking/deltas/tool results are noise.
function* progressLines(agent, e) {
  if (agent === 'claude') {
    if (e.type === 'system' && e.subtype === 'init') {
      yield `▸ agent session started (model ${e.model})`;
    } else if (e.type === 'assistant') {
      for (const block of e.message?.content ?? []) {
        if (block.type === 'tool_use') yield `→ ${block.name} ${toolSummary(block.input)}`;
        else if (block.type === 'text' && block.text?.trim()) yield `● ${truncate(block.text)}`;
      }
    } else if (e.type === 'result') {
      yield `✓ agent finished: ${e.num_turns} turns in ${humanDuration(e.duration_ms)}`;
    }
  } else {
    if (e.type === 'assistant.message' && e.data?.content?.trim()) {
      yield `● ${truncate(e.data.content)}`;
    } else if (/tool|command|exec/i.test(e.type ?? '') && !/status|loaded/.test(e.type ?? '')) {
      yield `→ ${e.type} ${truncate(JSON.stringify(e.data ?? ''), 120)}`;
    } else if (e.type === 'result') {
      yield `✓ agent finished in ${humanDuration(e.usage?.sessionDurationMs)}`;
    }
  }
}

async function stream(argv) {
  const { flags, positional } = parseFlags(argv);
  const [agent] = positional;
  const rawOut = flags['raw-out'];
  if (!agent || !rawOut) fail('stream needs: <claude|copilot> --raw-out <file>');
  const out = createWriteStream(rawOut);
  const rl = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of rl) {
    out.write(line + '\n');
    if (!line.trim()) continue;
    let event;
    try {
      event = JSON.parse(line);
    } catch {
      continue; // interleaved non-JSON noise stays in the raw file only
    }
    for (const msg of progressLines(agent, event)) console.log(msg);
  }
  await new Promise((resolve) => out.end(resolve));
}

// ---------------------------------------------------------------------------
// normalize
// ---------------------------------------------------------------------------

function normalizeClaude(raw, mode) {
  // Accepts both output formats: `json` (one result object) and `stream-json`
  // (JSONL events ending in a result event) — the result payload is the same.
  const r = parseJsonl(raw).findLast((e) => e.type === 'result');
  if (!r) throw new Error('no result event in the agent output');
  const usage = r.usage ?? {};
  return {
    record: {
      mode,
      agent: 'claude',
      models: Object.keys(r.modelUsage ?? {}),
      input_tokens: usage.input_tokens ?? 0,
      cache_read_tokens: usage.cache_read_input_tokens ?? 0,
      cache_write_tokens: usage.cache_creation_input_tokens ?? 0,
      output_tokens: usage.output_tokens ?? 0,
      cost_usd: r.total_cost_usd ?? null,
      premium_requests: null,
      num_turns: r.num_turns ?? null,
      duration_ms: r.duration_ms ?? null,
      api_duration_ms: r.duration_api_ms ?? null,
      session_id: r.session_id ?? null,
      code_changes: null,
    },
    log: r.result ?? '',
  };
}

// Recursively find objects that look like per-call token usage.
function* usageObjects(value) {
  if (Array.isArray(value)) {
    for (const v of value) yield* usageObjects(v);
  } else if (value && typeof value === 'object') {
    if (typeof value.inputTokens === 'number' && typeof value.outputTokens === 'number') {
      yield value;
    } else {
      for (const v of Object.values(value)) yield* usageObjects(v);
    }
  }
}

function parseJsonl(text) {
  const events = [];
  for (const line of text.split('\n')) {
    if (!line.trim()) continue;
    try {
      events.push(JSON.parse(line));
    } catch {
      // Not JSON (e.g. an interleaved warning) — skip.
    }
  }
  return events;
}

function normalizeCopilot(raw, mode, stateDir) {
  const events = parseJsonl(raw);
  const messages = events.filter((e) => e.type === 'assistant.message');
  const result = events.findLast((e) => e.type === 'result');
  const usage = result?.usage ?? {};
  const record = {
    mode,
    agent: 'copilot',
    models: [...new Set(messages.map((m) => m.data?.model).filter(Boolean))],
    input_tokens: null,
    cache_read_tokens: null,
    cache_write_tokens: null,
    output_tokens: messages.reduce((sum, m) => sum + (m.data?.outputTokens ?? 0), 0),
    cost_usd: null,
    premium_requests: usage.premiumRequests ?? null,
    num_turns: null,
    duration_ms: usage.sessionDurationMs ?? null,
    api_duration_ms: usage.totalApiDurationMs ?? null,
    session_id: result?.sessionId ?? null,
    code_changes: usage.codeChanges ?? null,
  };

  // The CLI reports premium requests on stdout but keeps per-call token usage
  // in its own session log. That layout is internal to the CLI, so it is
  // best-effort: enrich when present, report without token detail when not.
  try {
    const eventsPath = join(stateDir, record.session_id ?? '', 'events.jsonl');
    if (record.session_id && existsSync(eventsPath)) {
      const totals = { input_tokens: 0, cache_read_tokens: 0, cache_write_tokens: 0, output_tokens: 0 };
      let seen = false;
      for (const event of parseJsonl(readFileSync(eventsPath, 'utf8'))) {
        for (const u of usageObjects(event)) {
          seen = true;
          totals.input_tokens += u.inputTokens ?? 0;
          totals.cache_read_tokens += u.cacheReadTokens ?? 0;
          totals.cache_write_tokens += u.cacheWriteTokens ?? 0;
          totals.output_tokens += u.outputTokens ?? 0;
        }
      }
      if (seen) Object.assign(record, totals);
    }
  } catch {
    // Report without token detail.
  }

  return {
    record,
    log: messages.map((m) => m.data?.content ?? '').filter(Boolean).join('\n'),
  };
}

function normalize(argv) {
  const { flags, positional } = parseFlags(argv);
  const [agent, rawPath] = positional;
  const { mode, out } = flags;
  if (!agent || !rawPath || !mode || !out) {
    fail('normalize needs: <claude|copilot> <raw-file> --mode <mode> --out <file>');
  }
  let normalized;
  try {
    const raw = readFileSync(rawPath, 'utf8');
    if (agent === 'claude') {
      normalized = normalizeClaude(raw, mode);
    } else if (agent === 'copilot') {
      const stateDir = flags['state-dir'] ?? join(process.env.HOME ?? '', '.copilot', 'session-state');
      normalized = normalizeCopilot(raw, mode, stateDir);
    } else {
      fail(`unknown agent: ${agent}`);
    }
    writeFileSync(out, JSON.stringify(normalized.record, null, 2) + '\n');
  } catch (e) {
    fail(`could not normalize ${agent} output: ${e.message}`);
  }
  if (normalized.log && !('no-log' in flags)) console.log(normalized.log);
}

// ---------------------------------------------------------------------------
// report
// ---------------------------------------------------------------------------

const NOT_REPORTED = 'not reported';

function humanTokens(n) {
  if (n == null) return NOT_REPORTED;
  if (n >= 1_000_000) return `${Math.round(n / 100_000) / 10}M`;
  if (n >= 1_000) return `${Math.round(n / 100) / 10}k`;
  return String(n);
}

function humanDuration(ms) {
  if (ms == null) return NOT_REPORTED;
  const s = Math.round(ms / 1000);
  return `${Math.floor(s / 60)}m ${s % 60}s`;
}

function money(x) {
  if (x == null) return NOT_REPORTED;
  return `$${(Math.round(x * 100) / 100).toFixed(2)}`;
}

// The two agents report input differently, and combining fields must follow
// each one's semantics. Anthropic's input_tokens EXCLUDES the cache buckets,
// so the total read is their sum. Copilot's inputTokens already INCLUDES
// cache-written tokens (observed in real traces: inputTokens 25809 alongside
// cacheWriteTokens 25806), so it is reported as-is, not summed.
function tokensReadCell(r) {
  if (r.input_tokens == null) return NOT_REPORTED;
  if (r.agent === 'copilot') return humanTokens(r.input_tokens);
  const total = r.input_tokens + (r.cache_read_tokens ?? 0) + (r.cache_write_tokens ?? 0);
  let cell = humanTokens(total);
  if (total > 0 && r.cache_read_tokens > 0) {
    cell += ` (${Math.round((r.cache_read_tokens / total) * 100)}% from cache)`;
  }
  return cell;
}

// Sum, keeping null when no record reported the field at all.
function sumField(records, field) {
  const values = records.map((r) => r[field]).filter((v) => v != null);
  return values.length > 0 ? values.reduce((a, b) => a + b, 0) : null;
}

function aggregate(records) {
  return {
    agent: records[0].agent,
    models: [...new Set(records.flatMap((r) => r.models))],
    input_tokens: sumField(records, 'input_tokens'),
    cache_read_tokens: sumField(records, 'cache_read_tokens'),
    cache_write_tokens: sumField(records, 'cache_write_tokens'),
    output_tokens: sumField(records, 'output_tokens'),
    cost_usd: sumField(records, 'cost_usd'),
    premium_requests: sumField(records, 'premium_requests'),
    num_turns: sumField(records, 'num_turns'),
    duration_ms: sumField(records, 'duration_ms'),
  };
}

function renderFooter(records, total) {
  const lines = ['### Agent usage', ''];
  if (total.agent === 'claude') {
    lines.push(
      'As reported by Claude Code; the cost is computed by the agent from billed API usage.',
      '',
      '| Run | Model | Cost | Tokens read | Tokens written | Turns | Time |',
      '| --- | --- | --- | --- | --- | --- | --- |'
    );
    for (const r of records) {
      lines.push(
        `| ${r.mode} | ${r.models.join(', ')} | ${money(r.cost_usd)} | ${tokensReadCell(r)}` +
          ` | ${humanTokens(r.output_tokens)} | ${r.num_turns ?? '—'} | ${humanDuration(r.duration_ms)} |`
      );
    }
    lines.push(
      `| **total** | | **${money(total.cost_usd)}** | ${tokensReadCell(total)}` +
        ` | ${humanTokens(total.output_tokens)} | ${total.num_turns ?? '—'} | ${humanDuration(total.duration_ms)} |`
    );
  } else {
    lines.push(
      'As reported by the Copilot CLI. Copilot bills in premium requests, not dollars, so no dollar figure is shown.',
      '',
      '| Run | Model | Premium requests | Tokens read | Tokens written | Time |',
      '| --- | --- | --- | --- | --- | --- |'
    );
    for (const r of records) {
      lines.push(
        `| ${r.mode} | ${r.models.join(', ')} | ${r.premium_requests ?? NOT_REPORTED} | ${tokensReadCell(r)}` +
          ` | ${humanTokens(r.output_tokens)} | ${humanDuration(r.duration_ms)} |`
      );
    }
    lines.push(
      `| **total** | | **${total.premium_requests ?? NOT_REPORTED}** | ${tokensReadCell(total)}` +
        ` | ${humanTokens(total.output_tokens)} | ${humanDuration(total.duration_ms)} |`
    );
  }
  return lines.join('\n') + '\n';
}

function report() {
  const usageDir = process.env.USAGE_DIR;
  if (!usageDir) fail('report needs USAGE_DIR');

  // Chronological order: the update run precedes the review run.
  const names = existsSync(usageDir)
    ? readdirSync(usageDir).filter((n) => /^usage-.*\.json$/.test(n))
    : [];
  names.sort((a, b) => {
    const rank = (n) => (n === 'usage-update.json' ? 0 : n === 'usage-review.json' ? 1 : 2);
    return rank(a) - rank(b) || a.localeCompare(b);
  });

  const records = [];
  for (const name of names) {
    try {
      records.push(JSON.parse(readFileSync(join(usageDir, name), 'utf8')));
    } catch {
      console.error(`usage.mjs: skipping unreadable ${name}`);
    }
  }
  if (records.length === 0) {
    console.log('No agent usage records found; skipping the usage report.');
    return;
  }

  const total = aggregate(records);
  const footer = renderFooter(records, total);
  const footerFile = join(usageDir, 'usage-footer.md');
  writeFileSync(footerFile, footer);
  console.log(footer);

  if (process.env.GITHUB_OUTPUT) {
    appendFileSync(
      process.env.GITHUB_OUTPUT,
      [
        `models=${total.models.join(',')}`,
        `cost-usd=${total.cost_usd != null ? Math.round(total.cost_usd * 1e6) / 1e6 : ''}`,
        `premium-requests=${total.premium_requests ?? ''}`,
        `input-tokens=${total.input_tokens ?? ''}`,
        `output-tokens=${total.output_tokens ?? ''}`,
        `duration-ms=${total.duration_ms ?? ''}`,
        `footer-file=${footerFile}`,
      ].join('\n') + '\n'
    );
  }
}

// ---------------------------------------------------------------------------

const [command, ...rest] = process.argv.slice(2);
if (command === 'stream') await stream(rest);
else if (command === 'normalize') normalize(rest);
else if (command === 'report') report();
else fail(`unknown command: ${command ?? '(none)'} (expected 'stream', 'normalize', or 'report')`);
