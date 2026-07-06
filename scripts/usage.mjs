#!/usr/bin/env node
// Usage accounting for the review action. Everything reported comes directly
// from the agent's own output — nothing is estimated or priced from tables.
// Claude Code reports cost in USD; the Copilot CLI reports premium requests
// (its billing unit) and no dollar figure, so none is shown for it.
//
// Subcommands:
//   normalize claude  <raw-result.json>  --mode <update|review> --out <file>
//   normalize copilot <raw-stream.jsonl> --mode <update|review> --out <file> [--state-dir <dir>]
//       Writes the normalized usage record to --out and prints the agent's
//       final message(s) to stdout, for the CI job log.
//   report
//       Aggregates $USAGE_DIR/usage-*.json into a Markdown footer
//       ($USAGE_DIR/usage-footer.md) and $GITHUB_OUTPUT step outputs.

import { readFileSync, writeFileSync, existsSync, readdirSync, appendFileSync } from 'node:fs';
import { join } from 'node:path';

function fail(message) {
  console.error(`usage.mjs: ${message}`);
  process.exit(2);
}

function parseFlags(argv) {
  const flags = {};
  const positional = [];
  for (let i = 0; i < argv.length; i++) {
    if (argv[i].startsWith('--')) {
      flags[argv[i].slice(2)] = argv[++i];
    } else {
      positional.push(argv[i]);
    }
  }
  return { flags, positional };
}

// ---------------------------------------------------------------------------
// normalize
// ---------------------------------------------------------------------------

function normalizeClaude(raw, mode) {
  const r = JSON.parse(raw);
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
  if (normalized.log) console.log(normalized.log);
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
if (command === 'normalize') normalize(rest);
else if (command === 'report') report();
else fail(`unknown command: ${command ?? '(none)'} (expected 'normalize' or 'report')`);
