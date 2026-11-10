'use strict';

const test = require('node:test');
const assert = require('node:assert/strict');
const {
  publishCheckRunSummary,
  truncateUtf8,
  readLogs,
  wrapSummary,
  findJob,
  MAX_SUMMARY_BYTES,
} = require('../../scripts/publish-check-run-summary.js');

const context = { repo: { owner: 'umiturtle', repo: 'Z-Ts' }, runId: 42810958509 };
const workspace = '/workspace';
const noSleep = async () => {};

function makeCore() {
  const state = { warnings: [], infos: [], summaries: [] };
  const core = {
    info: (m) => state.infos.push(m),
    warning: (m) => state.warnings.push(m),
    debug: () => {},
    summary: {
      addRaw(text) {
        state.summaries.push(text);
        return this;
      },
      async write() {},
    },
  };
  return { core, state };
}

function makeGithub(options = {}) {
  const calls = { get: [], list: [], update: [] };
  let updateFailures = options.updateFailures ?? 0;
  const github = {
    rest: {
      repos: {
        async get(params) {
          calls.get.push(params);
          if (options.failGet) throw new Error('GET /repos failed');
          return { data: { full_name: options.fullName ?? 'umiturtle/ZigguraTs' } };
        },
      },
      actions: {
        async listJobsForWorkflowRun(params) {
          calls.list.push(params);
          if (options.failList) throw new Error('listJobsForWorkflowRun failed');
          return {
            data: {
              jobs: options.jobs ?? [
                { id: 101, name: 'Linux (Ubuntu 24.04 + Xvfb + WebKit2GTK 4.1)' },
                { id: 102, name: 'macOS (arm64 + WKWebView)' },
              ],
            },
          };
        },
      },
      checks: {
        async update(params) {
          calls.update.push(params);
          if (updateFailures > 0) {
            updateFailures -= 1;
            const err = new Error('fetch failed');
            err.status = 500;
            throw err;
          }
          return { data: {} };
        },
      },
    },
  };
  return { github, calls };
}

function makeFs(files) {
  return {
    existsSync: (p) => Object.prototype.hasOwnProperty.call(files, p),
    readFileSync: (p) => files[p],
  };
}

function baseOptions(extra = {}) {
  const { core, state } = makeCore();
  const { github, calls } = makeGithub(extra.githubOptions ?? {});
  return {
    args: {
      github,
      context,
      core,
      title: 'Linux CI Output',
      jobName: 'Linux (',
      logFiles: ['ci-output.log'],
      workspace,
      fsImpl: makeFs({ '/workspace/ci-output.log': 'OK screenshots host=gtk3 os=linux' }),
      sleep: noSleep,
      retries: 2,
    },
    core,
    state,
    calls,
  };
}

test('resolves the renamed repository before PATCH and publishes the log', async () => {
  const { args, state, calls } = baseOptions();
  const result = await publishCheckRunSummary(args);

  assert.equal(result.published, true);
  assert.equal(result.repo, 'umiturtle/ZigguraTs');
  assert.equal(result.checkRunId, 101);
  assert.deepEqual(calls.get[0], { owner: 'umiturtle', repo: 'Z-Ts' });
  assert.equal(calls.list[0].repo, 'ZigguraTs');
  assert.equal(calls.update[0].repo, 'ZigguraTs');
  assert.equal(calls.update[0].check_run_id, 101);
  assert.equal(calls.update[0].output.title, 'Linux CI Output');
  assert.match(calls.update[0].output.summary, /OK screenshots host=gtk3 os=linux/);
  assert.equal(state.summaries.length, 1);
  assert.ok(state.infos.some((m) => m.includes('renamed')));
});

test('falls back to the event-payload name when the lookup fails, without throwing', async () => {
  const { args, calls } = baseOptions({ githubOptions: { failGet: true } });
  const result = await publishCheckRunSummary(args);

  assert.equal(result.published, true);
  assert.equal(result.repo, 'umiturtle/Z-Ts');
  assert.equal(calls.update[0].repo, 'Z-Ts');
});

test('retries a transient 500 and succeeds on the next attempt', async () => {
  const { args, calls } = baseOptions({ githubOptions: { updateFailures: 1 } });
  const result = await publishCheckRunSummary(args);

  assert.equal(result.published, true);
  assert.equal(calls.update.length, 2);
  assert.equal(calls.list.length, 2);
});

test('a persistent API failure is a warning, not a CI failure', async () => {
  const { args, state } = baseOptions({ githubOptions: { updateFailures: 99 } });
  const result = await publishCheckRunSummary(args);

  assert.equal(result.published, false);
  assert.equal(result.reason, 'api-error');
  assert.match(result.error, /fetch failed/);
  assert.ok(state.warnings.some((m) => m.includes('Could not publish')));
  assert.equal(state.summaries.length, 1, 'the Step Summary fallback still ran');
});

test('a missing job keeps the Step Summary and returns job-not-found', async () => {
  const { args, state, calls } = baseOptions({
    githubOptions: { jobs: [{ id: 7, name: 'Cross-OS parity (same pixels, same layout)' }] },
  });
  const result = await publishCheckRunSummary(args);

  assert.equal(result.published, false);
  assert.equal(result.reason, 'job-not-found');
  assert.equal(calls.update.length, 0);
  assert.ok(state.warnings.some((m) => m.includes('No job named')));
});

test('summary is truncated by UTF-8 bytes and never splits a multi-byte character', () => {
  const japanese = 'あ'.repeat(30000); // 90,000 UTF-8 bytes
  const summary = wrapSummary(japanese);

  assert.ok(Buffer.byteLength(summary, 'utf8') <= MAX_SUMMARY_BYTES);
  assert.ok(summary.startsWith('```text\n'));
  assert.ok(summary.endsWith('\n```'));
  assert.equal(Buffer.byteLength(truncateUtf8('あいう', 4), 'utf8'), 3);
  assert.equal(truncateUtf8('abc', 2), 'ab');
});

test('multiple log files get headings and findJob prefers an exact name', () => {
  const text = readLogs(
    ['cli-smoke.log', 'bench.log'],
    workspace,
    makeFs({ '/workspace/cli-smoke.log': 'cli-smoke: OK', '/workspace/bench.log': 'bench: OK' })
  );
  assert.match(text, /### cli-smoke\.log\ncli-smoke: OK/);
  assert.match(text, /### bench\.log\nbench: OK/);

  const jobs = [{ id: 1, name: 'CLI smoke (macos-latest)' }, { id: 2, name: 'CLI smoke (ubuntu-24.04)' }];
  assert.equal(findJob(jobs, 'CLI smoke (ubuntu-24.04)').id, 2);
  assert.equal(findJob(jobs, 'Cross-OS parity'), null);
});
