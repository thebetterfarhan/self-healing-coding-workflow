import { spawn, execFile } from 'node:child_process';
import { randomUUID } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { promisify } from 'node:util';
import { mkdtemp, open, realpath, stat } from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { McpServer } from '@modelcontextprotocol/server';
import { serveStdio } from '@modelcontextprotocol/server/stdio';
import { z } from 'zod';

const exec = promisify(execFile);
const router = process.env.NODE_ENV === 'test' && process.env.AGENT_INTEROP_TEST_ROUTER
  ? process.env.AGENT_INTEROP_TEST_ROUTER
  : fileURLToPath(new URL('../agent-task.ps1', import.meta.url));
const backends = ['codex', 'commandcode', 'opencode'];
const jobs = new Map();
const maxRunning = 2;
const timeoutMs = 30 * 60 * 1000;
let closing = false;

export function validateHandoff(caller, target, task) {
  if (!backends.includes(caller) || !backends.includes(target)) throw new Error('Unknown CLI backend.');
  if (caller === target) throw new Error('Handoff target must be a different CLI.');
  if (process.env.AGENT_INTEROP_CHILD === '1') throw new Error('Delegated CLI cannot delegate again.');
  if (!task.trim() || task.length > 20000) throw new Error('Task must contain 1 to 20000 characters.');
}

function psArgs({ task, workdir, target, complexity, mode, preview }) {
  const args = ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', router,
    '-Task', task, '-WorkDir', workdir, '-Agent', target, '-Complexity', complexity,
    '-NoFallback', '-Headless', '-N', '1'];
  if (mode === 'read') args.push('-ReadOnly');
  if (preview) args.push('-Preview');
  return args;
}

async function existingDirectory(workdir) {
  const resolved = await realpath(workdir);
  if (!(await stat(resolved)).isDirectory()) throw new Error('Workdir is not a directory.');
  return resolved;
}

export async function createEditWorktree(workdir) {
  const cwd = await existingDirectory(workdir);
  const { stdout: rootText } = await exec('git', ['-C', cwd, 'rev-parse', '--show-toplevel'], { timeout: 10000 });
  const root = await realpath(rootText.trim());
  const relative = path.relative(root, cwd);
  if (relative.startsWith('..') || path.isAbsolute(relative)) throw new Error('Workdir is outside the Git repository.');
  if (relative) {
    let kind;
    try {
      const revision = `HEAD:${relative.split(path.sep).join('/')}`;
      kind = (await exec('git', ['-C', root, 'cat-file', '-t', revision], { timeout: 10000 })).stdout.trim();
    } catch { /* An untracked directory has no tree in HEAD. */ }
    if (kind !== 'tree') throw new Error(`Edit workdir ${cwd} is not a directory in HEAD; choose a tracked ancestor.`);
  }
  const base = await mkdtemp(path.join(os.tmpdir(), 'agent-interop-'));
  const checkout = path.join(base, 'checkout');
  await exec('git', ['-C', root, 'worktree', 'add', '--detach', '--', checkout, 'HEAD'], { timeout: 60000 });
  const targetDir = path.join(checkout, relative);
  try { await existingDirectory(targetDir); }
  catch { throw new Error(`Edit workdir missing after checkout: ${targetDir}. Worktree retained at ${checkout}.`); }
  return { root: checkout, workdir: targetDir };
}

async function previewRoute(options) {
  const { stdout, stderr } = await exec('powershell.exe', psArgs({ ...options, preview: true }), {
    timeout: 30000, maxBuffer: 1024 * 1024,
  });
  return (stdout + stderr).trim();
}

async function logTail(file) {
  const handle = await open(file, 'r');
  try {
    const size = (await handle.stat()).size;
    const length = Math.min(size, 8192);
    const buffer = Buffer.alloc(length);
    await handle.read(buffer, 0, length, size - length);
    return buffer.toString('utf8');
  } finally {
    await handle.close();
  }
}

function result(value, isError = false) {
  return { content: [{ type: 'text', text: JSON.stringify(value) }], isError };
}

function errorResult(error) {
  return result({ error: error.message }, true);
}

function buildServer(caller) {
  const server = new McpServer({ name: 'agent-interop', version: '1.0.0' }, { capabilities: { tools: {} } });
  const input = z.object({
    target: z.enum(backends),
    task: z.string(),
    workdir: z.string(),
    complexity: z.enum(['auto', 'quick', 'standard', 'deep']).default('auto'),
    mode: z.enum(['read', 'edit']).default('read'),
  });

  server.registerTool('agent_route_preview', {
    description: 'Preview model and reasoning tier for a different CLI without running the task.',
    inputSchema: input,
    annotations: { readOnlyHint: true },
  }, async (options) => {
    try {
      validateHandoff(caller, options.target, options.task);
      const workdir = await existingDirectory(options.workdir);
      return result({ route: await previewRoute({ ...options, workdir }) });
    } catch (error) { return errorResult(error); }
  });

  server.registerTool('agent_handoff_start', {
    description: 'Start a bounded task on another CLI. Read tasks use the current directory; edit tasks use a fresh detached Git worktree from HEAD, without uncommitted or ignored source files. Never delegate again, commit, push, merge, publish, deploy, or change files outside the worktree. Poll agent_handoff_status for the result.',
    inputSchema: input,
  }, async (options) => {
    let id;
    let checkout;
    try {
      validateHandoff(caller, options.target, options.task);
      if ([...jobs.values()].filter((job) => ['starting', 'running'].includes(job.status)).length >= maxRunning) {
        throw new Error('Two handoffs are already running; poll or wait for one to finish.');
      }
      id = randomUUID();
      jobs.set(id, { status: 'starting' });
      const original = await existingDirectory(options.workdir);
      const route = await previewRoute({ ...options, workdir: original });
      const tier = route.match(/^\s*Tier\s*:\s*(quick|standard|deep)\s*$/mi)?.[1];
      if (!tier) throw new Error('Router preview did not return a task tier.');
      checkout = options.mode === 'edit' ? await createEditWorktree(original) : null;
      const workdir = checkout?.workdir ?? original;
      const prompt = `${options.task}\n\nHandoff boundary: Work only in ${workdir}. Do not delegate to another agent or CLI. Do not commit, push, merge, create a PR, publish, deploy, change credentials, or alter security controls. ${options.mode === 'edit' ? 'Edit only inside this isolated worktree; report changed paths and checks.' : 'Research and review only; do not edit files.'}`;
      const directory = await mkdtemp(path.join(os.tmpdir(), 'agent-interop-log-'));
      const logfile = path.join(directory, 'output.log');
      const handle = await open(logfile, 'w');
      await handle.close();
      if (closing) throw new Error('MCP connection closed before task start.');
      const output = createWriteStream(logfile, { flags: 'a' });
      const child = spawn('powershell.exe', psArgs({ ...options, complexity: tier, task: prompt, workdir }), {
        env: { ...process.env, AGENT_INTEROP_CHILD: '1' },
        stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true,
      });
      child.stdout.pipe(output, { end: false });
      child.stderr.pipe(output, { end: false });
      const job = { id, status: 'running', target: options.target, mode: options.mode,
        route, workdir, worktree: checkout?.root ?? null, logfile, pid: child.pid,
        started: new Date().toISOString(), exitCode: null };
      jobs.set(id, job);
      const timer = setTimeout(() => {
        if (job.status !== 'running') return;
        job.status = 'timed_out';
        spawn('taskkill.exe', ['/PID', String(child.pid), '/T', '/F'], { stdio: 'ignore', windowsHide: true });
      }, timeoutMs);
      timer.unref();
      child.on('error', (error) => { clearTimeout(timer); job.status = 'failed'; job.error = error.message; });
      child.on('close', (code) => {
        output.end(() => {
          clearTimeout(timer);
          if (job.status === 'running') job.status = code === 0 ? 'completed' : 'failed';
          job.exitCode = code;
        });
      });
      child.unref();
      return result({ id, status: job.status, target: job.target, route, workdir,
        worktree: job.worktree, logfile, timeoutMinutes: timeoutMs / 60000,
        ...(checkout ? { warning: 'Edit worktree starts from HEAD; it excludes uncommitted and ignored files in the source checkout.' } : {}) });
    } catch (error) {
      if (id && jobs.get(id)?.status === 'starting') jobs.delete(id);
      return errorResult(new Error(checkout
        ? `${error.message} Edit worktree retained at ${checkout.root}.`
        : error.message));
    }
  });

  server.registerTool('agent_handoff_status', {
    description: 'Poll a handoff by job ID. Returns status, exit code, and the last 8 KiB of output.',
    inputSchema: z.object({ id: z.string() }), annotations: { readOnlyHint: true },
  }, async ({ id }) => {
    const job = jobs.get(id);
    if (!job) return result({ error: 'Unknown job ID; jobs live for this MCP server session only.' }, true);
    let outputTail;
    try { outputTail = await logTail(job.logfile); }
    catch (error) { outputTail = `Log unavailable: ${error.message}`; }
    return result({ id, status: job.status, exitCode: job.exitCode, error: job.error,
      workdir: job.workdir, worktree: job.worktree, logfile: job.logfile,
      outputTail });
  });
  return server;
}

async function stopActiveChildren() {
  closing = true;
  const active = [...jobs.values()].filter((job) => job.status === 'running' && job.pid);
  await Promise.all(active.map(async (job) => {
    job.status = 'stopped';
    try { await exec('taskkill.exe', ['/PID', String(job.pid), '/T', '/F'], { timeout: 10000 }); }
    catch { /* The child may have exited already. */ }
  }));
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const caller = process.argv[2];
  if (!backends.includes(caller)) {
    process.stderr.write('Usage: node server.mjs <codex|commandcode|opencode>\n');
    process.exitCode = 2;
  } else {
    serveStdio(() => buildServer(caller));
    process.stdin.once('end', () => { void stopActiveChildren(); });
    for (const signal of ['SIGINT', 'SIGTERM']) {
      process.once(signal, () => { void stopActiveChildren().finally(() => process.exit(0)); });
    }
  }
}
