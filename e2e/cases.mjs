// What each end-to-end case sends. Each step's response is kept in the result file.
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

export const TRACEPARENT = '00-0af7651916cd43dd8448eb211c80319c-b7ad6b7169203331-01';

async function call(base, method, path, { headers = {}, body } = {}) {
  const res = await fetch(`${base}${path}`, {
    method,
    headers: { 'content-type': 'application/json', ...headers },
    body: body ? JSON.stringify(body) : undefined,
  });
  return { method, path, status: res.status, body: (await res.text()).slice(0, 300) };
}

/** The requests every web case sends; `routes` names the paths each app has. */
async function web(base, routes) {
  const steps = [];
  for (let i = 0; i < 40; i++) {
    try {
      await fetch(`${base}${routes.ok}`);
      break;
    } catch {
      await sleep(1000);
    }
  }
  for (let i = 0; i < 12; i++) steps.push(await call(base, 'GET', routes.pid ?? routes.ok));
  steps.push(await call(base, 'GET', routes.ok, {
    headers: {
      traceparent: TRACEPARENT,
      baggage: 'enduser.id=u-42,session.id=s-9',
      authorization: 'Bearer secret-token',
      cookie: 'session=abc',
      'x-request-id': 'req-1',
    },
  }));
  if (routes.crash) steps.push(await call(base, 'GET', routes.crash));
  if (routes.unique) {
    const email = `dup-${Date.now()}@example.com`;
    steps.push(await call(base, 'POST', routes.unique, { body: { email } }));
    steps.push(await call(base, 'POST', routes.unique, { body: { email } }));
    if (routes.uniqueQuiet) steps.push(await call(base, 'POST', routes.uniqueQuiet, { body: { email } }));
  }
  if (routes.failingJob) steps.push(await call(base, 'GET', routes.failingJob));
  return steps;
}

export const CASES = {
  rails81: {
    services: ['web', 'sidekiq', 'jobs'],
    settle: 20_000,
    steps: () => web('http://localhost:3181', {
      ok: '/carts/42', pid: '/pid', crash: '/carts/7/total', unique: '/users', uniqueQuiet: '/users/quiet', failingJob: '/jobs/fail',
    }),
  },
  rails71: {
    services: ['web'],
    steps: () => web('http://localhost:3171', { ok: '/carts/42', crash: '/carts/7/total', unique: '/users', uniqueQuiet: '/users/quiet' }),
  },
  sinatra: {
    services: ['web'],
    steps: () => web('http://localhost:3191', { ok: '/carts/42', crash: '/carts/7/total' }),
  },
  rack: {
    services: ['web'],
    steps: () => web('http://localhost:3192', { ok: '/carts/42', crash: '/carts/7/total' }),
  },
  hanami: {
    services: ['web'],
    steps: () => web('http://localhost:3193', { ok: '/carts/42', crash: '/carts/7/total' }),
  },
  sidekiq: {
    services: ['sidekiq'],
    settle: 20_000,
    steps: async ({ compose }) => {
      await new Promise((r) => setTimeout(r, 8000));
      const run = compose(['run', '--rm', 'enqueue'], { timeout: 300_000 });
      return [{ exit: run.status, stderr: run.stderr.slice(-1500) }];
    },
  },
  script: {
    up: false,
    steps: async ({ compose }) => {
      const run = compose(['run', '--rm', 'script'], { timeout: 600_000 });
      return [{ exit: run.status, stdout: run.stdout.slice(-1500), stderr: run.stderr.slice(-3000) }];
    },
  },
  semantic: {
    up: false,
    steps: async ({ compose }) => {
      const run = compose(['run', '--rm', 'script'], { timeout: 600_000 });
      return [{ exit: run.status, stdout: run.stdout.slice(-3000), stderr: run.stderr.slice(-3000) }];
    },
  },
};
