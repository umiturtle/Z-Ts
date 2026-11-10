'use strict';

// Mirror a CI log into the job's Check Run summary.
//
// `actions/github-script` exposes `context.repo` from the *event payload*, which GitHub freezes
// when a run starts. If the repository is renamed while the run is in flight, that name stays at
// the old value: GET /repos/{owner}/{repo} still redirects, but PATCH /repos/{old}/check-runs/{id}
// fails with `HttpError: fetch failed` / HTTP 500. Resolve the canonical `full_name` with a GET
// before writing, and never let a diagnostic-only API call fail the build.
//
// The same log is also appended to `$GITHUB_STEP_SUMMARY`, so it survives an API outage entirely.

const fs = require('fs');
const path = require('path');

const MAX_SUMMARY_BYTES = 60000;
const WRAPPER_BYTES = 20; // "```text\n" + "\n```" plus a little slack
const DEFAULT_RETRIES = 2;

/** Truncate by UTF-8 bytes, never cutting a multi-byte character in half. */
function truncateUtf8(text, maxBytes) {
  if (maxBytes <= 0) return '';
  if (Buffer.byteLength(text, 'utf8') <= maxBytes) return text;
  let lo = 0;
  let hi = text.length;
  while (lo < hi) {
    const mid = Math.floor((lo + hi + 1) / 2);
    if (Buffer.byteLength(text.slice(0, mid), 'utf8') <= maxBytes) lo = mid;
    else hi = mid - 1;
  }
  return text.slice(0, lo);
}

/** Read the requested logs from the workspace, with a `### file` heading for each one. */
function readLogs(logFiles, workspace, fsImpl) {
  const chunks = [];
  for (const file of logFiles || []) {
    const full = path.isAbsolute(file) ? file : path.join(workspace, file);
    if (!fsImpl.existsSync(full)) continue;
    chunks.push(`### ${path.basename(file)}\n${fsImpl.readFileSync(full, 'utf8')}`);
  }
  return chunks.join('\n');
}

/** Wrap the log in a fenced code block that fits GitHub's Check Run summary limit. */
function wrapSummary(text) {
  return '```text\n' + truncateUtf8(text, MAX_SUMMARY_BYTES - WRAPPER_BYTES) + '\n```';
}

/** Resolve the repository name as it exists *now*, not as it existed when the run started. */
async function resolveRepository(github, context, core) {
  const fallback = { owner: context.repo.owner, repo: context.repo.repo };
  try {
    const response = await github.rest.repos.get({ owner: fallback.owner, repo: fallback.repo });
    const fullName = response && response.data && response.data.full_name;
    if (typeof fullName === 'string' && fullName.includes('/')) {
      const [owner, repo] = fullName.split('/');
      if (owner && repo) {
        if (owner !== fallback.owner || repo !== fallback.repo) {
          core?.info?.(`Repository was renamed: ${fallback.owner}/${fallback.repo} -> ${owner}/${repo}`);
        }
        return { owner, repo };
      }
    }
  } catch (err) {
    core?.debug?.(`Could not resolve the canonical repository name: ${err?.message ?? err}`);
  }
  return fallback;
}

/** Match an exact job name first, then a stable display-name prefix such as `Linux (`. */
function findJob(jobs, jobName) {
  if (!Array.isArray(jobs)) return null;
  return jobs.find((j) => j && j.name === jobName)
    ?? jobs.find((j) => j && typeof j.name === 'string' && j.name.startsWith(jobName))
    ?? null;
}

/**
 * Publish `logFiles` to the Check Run of `jobName`.
 * Returns a status object; it never throws because losing a log mirror must not fail CI.
 */
async function publishCheckRunSummary(options) {
  const {
    github,
    context,
    core,
    title,
    jobName,
    logFiles,
    runId = context.runId,
    workspace = process.env.GITHUB_WORKSPACE || process.cwd(),
    fsImpl = fs,
    retries = DEFAULT_RETRIES,
    sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  } = options;

  const raw = readLogs(logFiles, workspace, fsImpl) || '(no log)';
  const summary = wrapSummary(raw);

  // Durable fallback: the job Step Summary is rendered even when the Check Run API is unavailable.
  try {
    if (core?.summary && typeof core.summary.addRaw === 'function') {
      await core.summary.addRaw(summary).write();
    }
  } catch (err) {
    core?.warning?.(`Step Summary write failed: ${err?.message ?? err}`);
  }

  let lastError = null;
  let lastRepo = { owner: context.repo.owner, repo: context.repo.repo };
  for (let attempt = 0; attempt <= retries; attempt += 1) {
    try {
      const repo = await resolveRepository(github, context, core);
      lastRepo = repo;
      const response = await github.rest.actions.listJobsForWorkflowRun({
        owner: repo.owner,
        repo: repo.repo,
        run_id: runId,
        per_page: 100,
      });
      const me = findJob(response?.data?.jobs, jobName);
      if (!me) {
        core?.warning?.(`No job named '${jobName}' in run ${runId}; the log is in the Step Summary.`);
        return { published: false, reason: 'job-not-found', repo: `${repo.owner}/${repo.repo}` };
      }
      await github.rest.checks.update({
        owner: repo.owner,
        repo: repo.repo,
        check_run_id: me.id,
        output: { title, summary },
      });
      core?.info?.(`Published '${title}' to check run ${me.id} on ${repo.owner}/${repo.repo}.`);
      return { published: true, repo: `${repo.owner}/${repo.repo}`, checkRunId: me.id };
    } catch (err) {
      lastError = err;
      if (attempt < retries) await sleep(500 * (attempt + 1));
    }
  }

  const message = lastError?.message ?? String(lastError);
  core?.warning?.(
    `Could not publish '${title}' to the Check Run API (${lastRepo.owner}/${lastRepo.repo}): ` +
    `${message}. The log is still in the Step Summary.`
  );
  return {
    published: false,
    reason: 'api-error',
    repo: `${lastRepo.owner}/${lastRepo.repo}`,
    error: message,
  };
}

module.exports = {
  publishCheckRunSummary,
  truncateUtf8,
  readLogs,
  wrapSummary,
  resolveRepository,
  findJob,
  MAX_SUMMARY_BYTES,
  DEFAULT_RETRIES,
};
