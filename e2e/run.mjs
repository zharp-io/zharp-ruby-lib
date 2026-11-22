// End-to-end cases against a Zharp backend: a throwaway app per case, the case's docker compose
// stack up, its requests sent, then what Zharp stored (traces, spans, issues, logs) saved as JSON
// and summarised, the stack taken down and the app deleted.
//
//   ZHARP_API=http://localhost:3000/api/v1 ZHARP_TOKEN=<user JWT> ZHARP_WORKSPACE=3 node e2e/run.mjs rails81
//   KEEP=1 keeps the app and the stack.
import { execSync, spawnSync } from 'node:child_process';
import { mkdirSync, readFileSync, writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { CASES } from './cases.mjs';

const here = dirname(fileURLToPath(import.meta.url));
const API = process.env.ZHARP_API ?? 'http://localhost:3000/api/v1';
const token = (process.env.ZHARP_TOKEN ?? readFileSync(process.env.ZHARP_TOKEN_FILE, 'utf8')).trim();
const H = { Authorization: `Bearer ${token}`, 'x-workspace-id': process.env.ZHARP_WORKSPACE ?? '3', 'content-type': 'application/json' };
const api = async (path, init = {}) => (await fetch(`${API}/${path}`, { headers: H, ...init })).json();
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
const out = join(here, 'out');
mkdirSync(out, { recursive: true });

async function createApp(name) {
  for (const platform of ['ruby', 'otel']) {
    const res = await api('applications', { method: 'POST', body: JSON.stringify({ name, platform, framework: 'Rails' }) });
    if (res.data?.ingestKey) return { ...res.data, platform };
  }
  throw new Error('could not create an app');
}

for (const name of process.argv.slice(2)) {
  const kase = CASES[name];
  if (!kase) throw new Error(`no case ${name}`);
  const app = await createApp(`ruby-e2e-${name}-${Date.now() % 100000}`);
  console.log(`=== ${name}: app ${app.id} (platform ${app.platform})`);
  const dir = join(here, kase.dir ?? name);
  const env = { ...process.env, ZHARP_KEY: app.ingestKey, ZHARP_ENDPOINT: 'http://host.docker.internal:3000/api/v1/otlp', COMPOSE_PROJECT_NAME: `zharp-e2e-${name}` };
  const compose = (args, opts = {}) => spawnSync('docker', ['compose', ...args], { cwd: dir, env, encoding: 'utf8', ...opts });
  const result = { app: app.id, platform: app.platform };
  try {
    if (kase.compose !== false && kase.up !== false) {
      const up = compose(['up', '-d', '--wait', ...(kase.services ?? [])], { timeout: 900_000 });
      if (up.status !== 0) {
        console.log(up.stdout.slice(-2000), up.stderr.slice(-4000));
        console.log(compose(['logs', '--tail', '60']).stdout);
        throw new Error('compose up failed');
      }
    }
    result.steps = await kase.steps({ env, compose, dir });
    await sleep(kase.settle ?? 12_000);
    result.traces = (await api(`applications/${app.id}/traces?window=1h`)).data;
    const traceIds = [...new Set((result.traces?.traces ?? result.traces ?? []).map((t) => t.traceId))];
    result.traceDetails = {};
    for (const id of traceIds.slice(0, 40)) result.traceDetails[id] = (await api(`applications/traces/${id}`)).data;
    const issues = (await api(`applications/${app.id}/issues?window=1h`)).data;
    result.issues = [];
    for (const issue of Array.isArray(issues) ? issues : issues?.issues ?? []) {
      const detail = (await api(`applications/${app.id}/issues/${issue.id}`)).data;
      result.issues.push({ issue, detail });
    }
    result.logs = (await api(`applications/${app.id}/logs?window=1h&limit=200`)).data;
    if (kase.compose !== false) result.output = compose(['logs', '--no-color', '--tail', '400', ...(kase.logServices ?? [])]).stdout;
    writeFileSync(join(out, `${name}.json`), JSON.stringify(result, null, 2));
    console.log((kase.summary ?? summary)(result));
  } finally {
    if (process.env.KEEP !== '1') {
      if (kase.compose !== false) compose(['down', '-v', '--remove-orphans'], { timeout: 300_000 });
      await api(`applications/${app.id}`, { method: 'DELETE' });
    }
  }
}

export function summary(r) {
  const lines = [];
  const traces = r.traces?.traces ?? r.traces ?? [];
  lines.push(`traces (${traces.length}):`);
  for (const t of traces) lines.push(`  ${t.name ?? t.spanName} route=${t.httpRoute ?? t.route ?? ''} status=${t.httpStatus ?? t.status ?? ''} spans=${t.spanCount ?? ''} trace=${t.traceId}`);
  lines.push(`issues (${r.issues.length}):`);
  for (const { issue } of r.issues) lines.push(`  ${issue.title} events=${issue.events ?? issue.count ?? issue.eventCount} culprit=${issue.culprit ?? ''}`);
  return lines.join('\n');
}
