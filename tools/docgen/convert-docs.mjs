// Convert the workspace Markdown docs to a self-contained, screen-reader-friendly HTML set.
//
// Accessibility decisions (see README notes in the index page):
//   - skip link, then landmarks: header(banner) / nav(labelled) / main(labelled)
//   - one h1 per page; source headings demoted so the outline never skips a level
//   - every table gets a caption (accessible name) and scope="col" on its headers
//   - scrollable table wrappers become focusable regions only when they overflow
//   - ASCII schematics are exposed as role="img" with a written description
//   - visible focus ring, honours prefers-reduced-motion and prefers-color-scheme
//   - copy button and theme button carry explicit accessible names
import { readFileSync, writeFileSync, mkdirSync, statSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { Marked } from 'marked';

// The workspace root, derived from this file's location: tools/docgen -> ../..
const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const OUT = `${ROOT}/html`;

// --- command line -----------------------------------------------------------
// --only=a,b,c  render only these documents (by their output name, no .html)
// --out=DIR     write somewhere other than ./html
const argv = process.argv.slice(2);
const argOf = (name) => {
  const hit = argv.find(a => a.startsWith(`--${name}=`));
  return hit ? hit.slice(name.length + 3) : null;
};
const onlyArg = argOf('only');
const only = onlyArg ? new Set(onlyArg.split(',').map(s => s.trim())) : null;
const OUTDIR = argOf('out') || OUT;

const DOCS = [
  { src: 'START-HERE.md', out: 'start-here.html',
    title: 'START HERE', group: 'Start here',
    desc: 'The shortest path from "installed" to "useful". Read this one first.' },
  { src: 'SELF-HEALING-WORKFLOW.md', out: 'self-healing-workflow.html',
    title: 'The Self-Healing / Self-Repairing Workflow', group: 'Start here',
    desc: 'The complete guide: basics to advanced. Every layer, every nightly step, every runtime fallback.' },
  { src: 'WORKFLOW-USAGE.md', out: 'workflow-usage.html',
    title: 'Workflow Usage Guide', group: 'Start here',
    desc: 'The operator quick reference: cues, worktrees, release gate, lessons, daily self-repair.' },
  { src: 'tools/AGENT-SETUP.md', out: 'agent-setup.html',
    title: 'Agent Setup', group: 'Reference',
    desc: 'How Codex, OpenCode and Command Code are wired together: routing, roster, MCP handoff, permissions.' },
  { src: 'tools/DEV-SETUP.md', out: 'dev-setup.html',
    title: 'Developer Environment Setup', group: 'Reference',
    desc: 'Toolchain bootstrap for the Windows dev environment.' },
  { src: 'tools/HANDOVER.md', out: 'handover.html',
    title: 'Tools Handover', group: 'Reference',
    desc: 'Current state, evidence and next action for the tooling layer.' },
  { src: 'AGENTS.md', out: 'workspace-agents.html',
    title: 'Codex Workspace Instructions', group: 'Reference',
    desc: 'The Documents/Codex workspace AGENTS.md — workspace facts layered on the global policy.' },
  { src: 'AGENTS-compat.md', out: 'agents-compat.html',
    title: 'Compatibility Notes', group: 'Reference',
    desc: 'Dependency, SDK, compiler and build-tool baseline rules for compatibility work.' },
  { src: 'WORKFLOW-AUDIT-2026-10-14.md', out: 'audit-2026-10-14.html',
    title: 'Workflow Audit — 2026-10-14', group: 'Audits',
    desc: 'Periodic audit of the workflow configuration.' },
  { src: 'WORKFLOW-AUDIT-2026-10-18.md', out: 'audit-2026-10-18.html',
    title: 'Workflow Audit — 2026-10-18', group: 'Audits',
    desc: 'Periodic audit of the workflow configuration.' },
];

// Hand-written descriptions for the ASCII flow schematics. A screen reader
// reads a box-drawn diagram as noise; role="img" plus a written description
// replaces it with one spoken sentence.
//
// Only genuine flow/architecture diagrams get this. File trees are listings:
// they stay as readable <pre> text, which a screen reader can follow.
const DIAGRAM_DESCRIPTIONS = [
  ['   YOUR TASKS',
   'Architecture diagram. A task enters at the top and goes into a router, which ' +
   'classifies it as quick, standard or deep, picks a backend — Codex, Command Code or ' +
   'OpenCode — and picks a model, then runs it. If the run fails, the router falls back ' +
   'to a free model, then to another backend, and records the outcome. Below the router ' +
   'sit three instruction sources: Codex, Command Code and OpenCode, plus a memory and ' +
   'taste learning layer. A nightly self-repair job at 03:00 runs eleven steps, snapshots ' +
   'and rolls back, and regenerates the inputs the router consumes.'],
  ['BEFORE',
   'Flow diagram of the snapshot and rollback sequence for one repair step. ' +
   'Before the step runs: read the list of files the step will write; for each file, ' +
   'compute a SHA-256 hash over the whole tree — path, directory flag and file hash, ' +
   'sorted and serialised — copy it into the backup directory, re-hash the copy, and ' +
   'abort if the copy hash differs from the source hash; write that hash alongside the ' +
   'copy; then write a manifest listing each entry with its backup directory, whether the ' +
   'file existed beforehand, and its target path, plus a hash of the manifest itself. ' +
   'Then the step runs. If it exits zero, the run continues. If it exits non-zero: ' +
   'append its full output to the failure log, then restore — re-hash the manifest and ' +
   'abort if it changed, check the entry count matches, check every entry path, existed ' +
   'flag and target against the expected list, re-hash each snapshot and abort if it ' +
   'changed, and only then write the snapshots back. Files the step created are deleted ' +
   'rather than restored, so a rolled-back step leaves no trace.'],
  ['primary run',
   'Flow diagram of the fallback chain. The primary run is attempted first. If it fails ' +
   'with an infrastructure signature — a rate limit, plan restriction, auth failure, or ' +
   'unreachable host — the same backend is retried once on a free model. If that also ' +
   'fails, the same task is re-run once on a different command-line interface, using ' +
   'that backend’s model for the tier. If that fails too, the script throws and reports ' +
   'the log paths.'],
  ['Codex session',
   'Flow diagram of the memory pipeline. A Codex session produces a raw rollout summary. ' +
   'The curate step extracts the title, the outcome and the learning bullets verbatim — ' +
   'no model is called, so nothing can be invented — and writes one structured note. The ' +
   'consolidate step deduplicates those bullets against the existing long-term memory ' +
   'file and appends the novel ones, grouped by topic under a dated heading. The next ' +
   'session reads the consolidated memory, which makes the following session better.'],
  ['You work with Command Code',
   'Flow diagram of the taste pipeline. Working with Command Code causes preferences to ' +
   'be learned into the taste file. The sync step renders that file into a generated block ' +
   'delimited by taste begin and taste end markers and injects it into the instruction ' +
   'file of every agent, so Codex, OpenCode, Command Code, Claude and Gemini all behave ' +
   'consistently. A separate promotion step scans the notes for preferences that repeat ' +
   'at least twice and proposes them in the taste candidates file for human approval. ' +
   'Once approved they re-enter the taste file and the cycle repeats.'],
];

function escapeHtml(s) {
  return String(s).replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;');
}
function escapeAttr(s) {
  return escapeHtml(s).replace(/"/g, '&quot;').replace(/'/g, '&#39;');
}
function slugify(text) {
  return text.toLowerCase().replace(/[^\w\s-]/g, '').trim().replace(/\s+/g, '-');
}

// Walk every token, including those nested in blockquotes and lists.
function walk(tokens, fn) {
  for (const t of tokens) {
    fn(t);
    if (Array.isArray(t.tokens)) walk(t.tokens, fn);
    if (Array.isArray(t.items)) for (const it of t.items) walk([it], fn);
  }
}

const CSS = `
:root{
  --bg:#ffffff; --bg-soft:#f6f7f9; --bg-code:#f2f3f5; --fg:#1a1d21; --fg-dim:#5b6470;
  --fg-faint:#7b838d; --accent:#0b5fbf; --accent-soft:#e8f0fc; --border:#dfe3e8;
  --mark:#fff3c4; --shadow:0 1px 2px rgba(0,0,0,.06),0 4px 16px rgba(0,0,0,.06);
  --code:#24292f; --focus:#0b5fbf;
}
@media (prefers-color-scheme:dark){
  :root{
    --bg:#111418; --bg-soft:#171b21; --bg-code:#1b2027; --fg:#dfe3e8; --fg-dim:#a5aeba;
    --fg-faint:#7c8794; --accent:#79bcff; --accent-soft:#16273d; --border:#2b323b;
    --mark:#4a3f14; --shadow:0 1px 2px rgba(0,0,0,.4),0 4px 16px rgba(0,0,0,.35);
    --code:#e6edf3; --focus:#8ec5ff;
  }
}
html[data-theme=light]{ color-scheme:light; }
html[data-theme=dark]{
  color-scheme:dark;
  --bg:#111418; --bg-soft:#171b21; --bg-code:#1b2027; --fg:#dfe3e8; --fg-dim:#a5aeba;
  --fg-faint:#7c8794; --accent:#79bcff; --accent-soft:#16273d; --border:#2b323b;
  --mark:#4a3f14; --shadow:0 1px 2px rgba(0,0,0,.4),0 4px 16px rgba(0,0,0,.35);
  --code:#e6edf3; --focus:#8ec5ff;
}
*{box-sizing:border-box}
html{scroll-behavior:smooth}
@media (prefers-reduced-motion:reduce){
  html{scroll-behavior:auto}
  *{animation-duration:.01ms!important; transition-duration:.01ms!important}
}
body{
  margin:0; background:var(--bg); color:var(--fg);
  font:17px/1.7 -apple-system,BlinkMacSystemFont,"Segoe UI",Roboto,"Helvetica Neue",Arial,sans-serif;
  -webkit-font-smoothing:antialiased;
}
a{color:var(--accent); text-decoration:underline; text-underline-offset:2px}
a:hover{text-decoration-thickness:2px}
code,pre,kbd,samp{font-family:ui-monospace,SFMono-Regular,"SF Mono",Menlo,Consolas,"Liberation Mono",monospace}

/* ---- focus: always visible, never removed ---- */
:focus-visible{outline:3px solid var(--focus); outline-offset:2px; border-radius:4px}
.skip{
  position:absolute; left:12px; top:-100px; z-index:200;
  background:var(--accent); color:#fff; padding:12px 20px; border-radius:0 0 10px 10px;
  font-weight:650; text-decoration:none; transition:top .15s;
}
.skip:focus{top:0}

/* ---- landmarks ---- */
.topbar{
  position:sticky; top:0; z-index:50; display:flex; align-items:center; gap:14px;
  padding:10px 20px; background:var(--bg); border-bottom:1px solid var(--border);
}
.topbar .brand{font-weight:650; letter-spacing:-.01em; font-size:15px; color:var(--fg)}
.topbar .spacer{flex:1}
.btn{
  border:1px solid var(--border); background:var(--bg-soft); color:var(--fg-dim);
  border-radius:8px; padding:6px 12px; font-size:13px; cursor:pointer; font-family:inherit;
}
.btn:hover{color:var(--fg); border-color:var(--fg-faint)}
.wrap{display:grid; grid-template-columns:300px minmax(0,1fr); gap:44px; max-width:1400px; margin:0 auto; padding:0 24px}
.tocbox{position:sticky; top:56px; align-self:start; max-height:calc(100vh - 76px); display:flex; flex-direction:column}
.tocbox > summary{
  cursor:pointer; padding:12px 4px; font-size:12px; letter-spacing:.08em; text-transform:uppercase;
  color:var(--fg-faint); font-weight:650; list-style:none;
}
.tocbox > summary::-webkit-details-marker{display:none}
.tocbox > summary::before{content:"\\25B8 "}
.tocbox[open] > summary::before{content:"\\25BE "}
nav.toc{
  overflow-y:auto; padding:0 4px 40px 0; font-size:13.5px; line-height:1.5;
  border-left:1px solid var(--border); padding-left:0;
}
nav.toc ol{list-style:none; margin:0; padding:0}
nav.toc li{margin:0}
nav.toc a{
  display:block; padding:5px 10px 5px 12px; color:var(--fg-dim);
  border-left:3px solid transparent; margin-left:-1px; overflow:hidden; text-overflow:ellipsis; white-space:nowrap;
}
nav.toc a:hover{color:var(--fg); text-decoration:none; background:var(--bg-soft)}
nav.toc a.active{color:var(--accent); border-left-color:var(--accent); font-weight:600}
nav.toc .d2{padding-left:26px; font-size:12.8px}
nav.toc .d3{padding-left:42px; font-size:12.4px; color:var(--fg-faint)}
nav.toc .d4{padding-left:58px; font-size:12px; color:var(--fg-faint)}
main{padding:34px 0 100px; min-width:0}
main > article{max-width:920px}

/* ---- content ---- */
h1,h2,h3,h4{line-height:1.25; letter-spacing:-.015em; scroll-margin-top:72px}
h1{font-size:2.1rem; margin:0 0 .5em; padding-bottom:.35em; border-bottom:1px solid var(--border)}
h2{font-size:1.45rem; margin:2.3em 0 .7em; padding-bottom:.25em; border-bottom:1px solid var(--border)}
h3{font-size:1.15rem; margin:1.8em 0 .55em}
h4{font-size:1.02rem; margin:1.5em 0 .5em; color:var(--fg-dim)}
p{margin:0 0 1.1em}
ul,ol{margin:0 0 1.1em; padding-left:1.5em}
li{margin:.3em 0}
li > ul,li > ol{margin:.3em 0}
hr{border:0; border-top:1px solid var(--border); margin:2.6em 0}
blockquote{
  margin:1.2em 0; padding:.8em 1.15em; border-left:4px solid var(--accent);
  background:var(--accent-soft); border-radius:0 8px 8px 0;
}
blockquote > :last-child{margin-bottom:0}
.tw{overflow-x:auto; margin:1.3em 0; border:1px solid var(--border); border-radius:10px}
.tw:focus-visible{outline-offset:-1px}
table{border-collapse:collapse; width:100%; font-size:.93em; background:var(--bg)}
caption{caption-side:top; text-align:left; padding:10px 12px; color:var(--fg-dim); font-size:.9em}
th,td{border-bottom:1px solid var(--border); border-right:1px solid var(--border); padding:9px 12px; text-align:left; vertical-align:top}
th{background:var(--bg-soft); font-weight:650; white-space:nowrap}
tr:last-child td{border-bottom:0}
th:last-child,td:last-child{border-right:0}
tbody tr:nth-child(even) td{background:color-mix(in srgb,var(--bg-soft) 55%,transparent)}
img{max-width:100%}
mark{background:var(--mark); color:inherit; padding:0 .15em; border-radius:3px}
:not(pre) > code{
  background:var(--bg-code); padding:.16em .38em; border-radius:5px; font-size:.875em;
  border:1px solid var(--border); word-break:break-word;
}
pre{
  background:var(--bg-code); border:1px solid var(--border); border-radius:10px;
  padding:14px 16px; overflow-x:auto; margin:1.25em 0; position:relative; line-height:1.55;
}
pre code{background:none; border:0; padding:0; font-size:.845em; color:var(--code)}
pre[role=img]{white-space:pre}
.copy{
  position:absolute; top:8px; right:8px; opacity:.6; transition:opacity .15s;
  border:1px solid var(--border); background:var(--bg); color:var(--fg-dim);
  border-radius:6px; padding:4px 10px; font-size:12px; cursor:pointer; font-family:inherit;
}
pre:hover .copy,.copy:focus-visible{opacity:1}
.copy.done{color:#1a7f37; border-color:#1a7f37; opacity:1}
.subtitle{color:var(--fg-dim); font-size:1.04rem; margin:0 0 2em}
.meta{color:var(--fg-faint); font-size:13px; margin:0 0 2.4em; padding-bottom:1.2em; border-bottom:1px solid var(--border)}
.nextlink{margin-top:3.5em; padding-top:1.2em; border-top:1px solid var(--border); font-size:.94rem}
.sr-only{
  position:absolute!important; width:1px; height:1px; padding:0; margin:-1px;
  overflow:hidden; clip:rect(0 0 0 0); white-space:nowrap; border:0;
}

/* ---- print ---- */
@media print{
  .topbar,nav.toc,.tocbox > summary,.copy,.skip{display:none!important}
  .wrap{display:block; padding:0}
  main{padding:0}
  body{font-size:11pt; background:#fff; color:#000}
  h2,h3{page-break-after:avoid}
  pre,.tw,table,blockquote{page-break-inside:avoid}
  a{color:inherit}
}
@media (max-width:920px){
  .wrap{grid-template-columns:1fr; gap:0; padding:0 18px}
  .tocbox{position:static; max-height:none}
  main{padding-top:22px}
}
`;

const JS = `
(function(){
  var root=document.documentElement;
  var status=document.getElementById('sr-status');
  function say(msg){ if(status){ status.textContent=''; setTimeout(function(){ status.textContent=msg; },40); } }

  /* ---- theme: auto -> light -> dark ---- */
  var MODES=['auto','light','dark'];
  var btn=document.getElementById('theme');
  function current(){ return localStorage.getItem('doc-theme')||'auto'; }
  function apply(m){
    if(m==='auto'){ root.removeAttribute('data-theme'); }
    else { root.setAttribute('data-theme',m); }
    localStorage.setItem('doc-theme',m);
    if(btn){
      btn.textContent='Theme: '+m;
      btn.setAttribute('aria-label','Colour theme: '+m+'. Activate to change.');
    }
  }
  apply(current());
  if(btn){
    btn.addEventListener('click',function(){
      var next=MODES[(MODES.indexOf(current())+1)%MODES.length];
      apply(next);
      say('Colour theme set to '+next);
    });
  }

  /* ---- copy buttons ---- */
  document.querySelectorAll('pre').forEach(function(pre){
    if(pre.getAttribute('role')==='img') return;
    var b=document.createElement('button');
    b.className='copy'; b.type='button'; b.textContent='copy';
    b.setAttribute('aria-label','Copy code block to clipboard');
    b.addEventListener('click',function(){
      var code=pre.querySelector('code');
      var text=code?code.innerText:pre.innerText;
      var done=function(){ b.textContent='copied'; b.classList.add('done'); say('Code copied to clipboard');
        setTimeout(function(){ b.textContent='copy'; b.classList.remove('done'); },1800); };
      if(navigator.clipboard&&navigator.clipboard.writeText){ navigator.clipboard.writeText(text).then(done).catch(function(){}); }
      else { say('Copy failed: clipboard unavailable'); }
    });
    pre.appendChild(b);
  });

  /* ---- scrollable tables become focusable regions only when they overflow ---- */
  function markOverflow(){
    document.querySelectorAll('.tw').forEach(function(w){
      if(w.scrollWidth>w.clientWidth+2){
        w.setAttribute('tabindex','0');
        w.setAttribute('role','region');
        if(!w.getAttribute('aria-label')) w.setAttribute('aria-label','Scrollable table');
      } else {
        w.removeAttribute('tabindex'); w.removeAttribute('role');
      }
    });
  }
  markOverflow();
  window.addEventListener('resize',markOverflow);

  /* ---- toc: collapsible on narrow screens, open on wide ---- */
  var box=document.getElementById('tocbox');
  function sizeToc(){ if(box) box.open = window.innerWidth>=920; }
  sizeToc(); window.addEventListener('resize',sizeToc);

  /* ---- scroll spy ---- */
  var links={};
  document.querySelectorAll('nav.toc a').forEach(function(a){ links[a.getAttribute('href').slice(1)]=a; });
  var heads=Array.prototype.slice.call(document.querySelectorAll('main h2[id],main h3[id]'));
  if(heads.length && 'IntersectionObserver' in window){
    var visible={};
    var io=new IntersectionObserver(function(entries){
      entries.forEach(function(e){ visible[e.target.id]=e.isIntersecting; });
      var active=null;
      for(var i=0;i<heads.length;i++){ if(visible[heads[i].id]){ active=heads[i].id; break; } }
      if(!active){
        for(var j=heads.length-1;j>=0;j--){
          if(heads[j].getBoundingClientRect().top<130){ active=heads[j].id; break; }
        }
      }
      Object.keys(links).forEach(function(k){ links[k].classList.remove('active'); });
      if(active&&links[active]) links[active].classList.add('active');
    },{rootMargin:'0px 0px -70% 0px',threshold:0});
    heads.forEach(function(h){ io.observe(h); });
  }
})();
`;

function renderDoc(md, fallbackTitle) {
  const marked = new Marked({ gfm: true, breaks: false });
  const tokens = marked.lexer(md);

  let title = fallbackTitle;
  if (tokens[0] && tokens[0].type === 'heading' && tokens[0].depth === 1) {
    title = tokens[0].text.replace(/[`*_]/g, '').trim();
    tokens.shift();
  }

  let base = Infinity;
  walk(tokens, (t) => { if (t.type === 'heading') base = Math.min(base, t.depth); });
  if (!isFinite(base)) base = 2;

  const seen = {};
  const slugOf = new Map();
  const levelOf = new Map();
  walk(tokens, (t) => {
    if (t.type !== 'heading') return;
    let s = slugify(t.text);
    const n = (seen[s] || 0) + 1;
    seen[s] = n;
    if (n > 1) s = `${s}-${n - 1}`;
    slugOf.set(t, s);
    levelOf.set(t, Math.min(6, t.depth - base + 2));
  });

  let lastHeading = '';
  let lastHeadingText = '';

  marked.use({
    renderer: {
      heading(token) {
        const text = this.parser.parseInline(token.tokens);
        const lv = levelOf.get(token) || token.depth;
        const id = slugOf.get(token) || '';
        lastHeading = id;
        lastHeadingText = token.text.replace(/[`*_]/g, '').trim();
        return `<h${lv} id="${id}">${text}</h${lv}>\n`;
      },
      table(token) {
        let header = '';
        let body = '';
        if (token.header && token.header.length) {
          let cells = '';
          for (const cell of token.header) cells += this.tablecell(cell);
          header = '<thead><tr>' + cells.replace(/<th(?![^>]*scope=)([^>]*)>/g, '<th scope="col"$1>') + '</tr></thead>';
        }
        if (token.rows && token.rows.length) {
          let rows = '';
          for (const row of token.rows) {
            let cells = '';
            for (const cell of row) cells += this.tablecell(cell);
            rows += '<tr>' + cells + '</tr>';
          }
          body = '<tbody>' + rows + '</tbody>';
        }
        const cap = lastHeadingText
          ? `<caption class="sr-only">${escapeHtml(lastHeadingText)}</caption>`
          : '';
        return `<div class="tw"><table>${cap}${header}${body}</table></div>\n`;
      },
      code(token) {
        const raw = token.escaped ? token.text : escapeHtml(token.text);
        // Flow/architecture diagrams only. File trees and listings stay as
        // readable text, because a screen reader can follow a tree line by line.
        const isFlow = /[▼▲◀▶┌┐]/.test(raw);
        let label = '';
        if (isFlow) {
          for (const [needle, desc] of DIAGRAM_DESCRIPTIONS) {
            if (raw.includes(needle)) { label = desc; break; }
          }
          if (!label) label = (lastHeadingText ? lastHeadingText : 'Schematic') + ' — schematic diagram';
        }
        const attrs = isFlow ? ` role="img" aria-label="${escapeAttr(label)}"` : '';
        const lang = token.lang ? ` class="language-${escapeAttr(token.lang)}"` : '';
        return `<pre${attrs}><code${lang}>${raw}</code></pre>\n`;
      },
    },
  });

  const body = marked.parser(tokens);

  let toc = '<ol>\n';
  walk(tokens, (t) => {
    if (t.type !== 'heading') return;
    const lv = levelOf.get(t);
    if (lv > 4) return;
    const text = t.text.replace(/[`*_]/g, '').trim();
    toc += `<li class="d${lv}"><a href="#${slugOf.get(t)}">${escapeHtml(text)}</a></li>\n`;
  });
  toc += '</ol>';

  return { title, body, toc };
}

function page({ title, body, toc, subtitle, meta, footer }) {
  return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>${escapeHtml(title)}</title>
<meta name="generator" content="marked 18.1.1">
<style>${CSS}</style>
</head>
<body>
<a class="skip" href="#content">Skip to main content</a>
<header class="topbar">
  <a class="brand" href="index.html">&#8592; Documentation index</a>
  <span class="spacer"></span>
  <button class="btn" id="theme" type="button">Theme: auto</button>
</header>
<div class="wrap">
<details class="tocbox" id="tocbox" open>
  <summary>Contents</summary>
  <nav class="toc" aria-label="Contents">
${toc}
  </nav>
</details>
<main id="content" tabindex="-1" aria-label="${escapeAttr(title)}">
<article>
<h1 id="doc-title">${escapeHtml(title)}</h1>
${subtitle ? `<p class="subtitle">${escapeHtml(subtitle)}</p>` : ''}
${meta ? `<p class="meta">${meta}</p>` : ''}
${body}
${footer}
</article>
</main>
</div>
<div id="sr-status" class="sr-only" role="status" aria-live="polite"></div>
<script>${JS}</script>
</body>
</html>
`;
}

mkdirSync(OUTDIR, { recursive: true });

const rendered = [];
for (const d of DOCS) {
  if (only && !only.has(d.out.replace(/\.html$/, ''))) continue;
  const src = `${ROOT}/${d.src}`;
  let md;
  try { md = readFileSync(src, 'utf8'); }
  catch { console.log(`SKIP (missing): ${d.src}`); continue; }
  // Normalise the line endings: a Windows checkout has CRLF and a Linux one
  // has LF, and the difference would otherwise end up inside the rendered
  // code blocks, so the same source would produce different HTML on the
  // machine that wrote it and the machine that published it.
  md = md.replace(/\r\n/g, '\n');

  const { title, body, toc } = renderDoc(md, d.title);

  const bytes = statSync(src).size;
  // No modification date and no byte count here: a checkout stamps every file
  // with the time it was cloned, and the line endings differ between Windows
  // and Linux, so either would make the output differ on every machine and
  // the committed HTML could never be compared with a fresh render.
  const meta = `Source <code>${escapeHtml(d.src)}</code>`;

  const html = page({ title, body, toc, meta,
    footer: `<p class="nextlink">Generated from the Markdown source. Edit the <code>.md</code> file and re-run the converter.</p>` });

  writeFileSync(`${OUTDIR}/${d.out}`, html, 'utf8');
  rendered.push({ ...d, bytes, out: d.out });
  console.log(`OK  ${d.src} -> html/${d.out}  (${(html.length / 1024).toFixed(1)} KB html)`);
}

// ---- index ----
const groups = {};
for (const d of rendered) (groups[d.group] ||= []).push(d);

let cards = '';
for (const [group, list] of Object.entries(groups)) {
  cards += `<h2 id="g-${group.replace(/\\s+/g, '-').toLowerCase()}">${escapeHtml(group)}</h2>\n<div class="cards">\n`;
  for (const d of list) {
    cards += `<a class="card" href="${d.out}">
  <span class="card-title">${escapeHtml(d.title)}</span>
  <span class="card-desc">${escapeHtml(d.desc)}</span>
  <span class="card-meta"><code>${escapeHtml(d.src)}</code> &middot; ${d.bytes.toLocaleString()} bytes</span>
</a>\n`;
  }
  cards += '</div>\n';
}
const indexHtml = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta name="color-scheme" content="light dark">
<title>Workflow Documentation</title>
<meta name="generator" content="marked 18.1.1">
<style>${CSS}
.wrap{display:block; max-width:1000px; margin:0 auto; padding:0 24px}
.cards{display:grid; grid-template-columns:repeat(auto-fill,minmax(300px,1fr)); gap:14px; margin:1.2em 0 2.4em}
.card{
  display:flex; flex-direction:column; gap:8px; padding:16px 18px; border:1px solid var(--border);
  border-radius:12px; background:var(--bg-soft); color:var(--fg); text-decoration:none; box-shadow:var(--shadow);
}
.card:hover{border-color:var(--accent); text-decoration:none}
.card-title{font-weight:650; font-size:15.5px; letter-spacing:-.01em}
.card-desc{color:var(--fg-dim); font-size:13.5px; line-height:1.55}
.card-meta{color:var(--fg-faint); font-size:12px; margin-top:auto; padding-top:6px}
</style>
</head>
<body>
<a class="skip" href="#content">Skip to main content</a>
<header class="topbar">
  <span class="brand">Workflow Documentation</span>
  <span class="spacer"></span>
  <button class="btn" id="theme" type="button">Theme: auto</button>
</header>
<div class="wrap"><main id="content" tabindex="-1" aria-label="Workflow documentation index">
<article>
<h1 id="doc-title">Workflow Documentation</h1>
<p class="subtitle">The Codex / OpenCode / Command Code self-healing workflow, generated from the Markdown sources in <code>Documents/Codex</code>.</p>
<p class="meta">${rendered.length} documents &middot; generated from Markdown with marked 18.1.1 &middot; every page is self-contained (no external assets)</p>
<nav aria-label="Documents">
${cards}
</nav>
<h2 id="regenerating">Regenerating</h2>
<p>These pages are generated. Edit the <code>.md</code> source and re-run the converter; the HTML is overwritten in place.</p>
<pre><code>cd ~/Documents/Codex/tools/docgen
node convert-docs.mjs
node verify-html.mjs</code></pre>
<p>Output lands in <code>~/Documents/Codex/html/</code>. The only dependency is <code>marked</code> (MIT), installed locally in <code>tools/docgen/node_modules</code>.</p>
<h2 id="accessibility">Accessibility notes</h2>
<p>These pages are built for screen-reader and keyboard use:</p>
<ul>
<li>A <strong>skip link</strong> jumps straight to the main content; the page is divided into labelled <code>banner</code>, <code>navigation</code> and <code>main</code> landmarks.</li>
<li>Each page has exactly one <code>h1</code>, and headings never skip a level, so a heading list is a usable table of contents.</li>
<li>Every table carries a caption and <code>scope="col"</code> headers. A table that scrolls sideways becomes a focusable region announced as such.</li>
<li>ASCII schematics are exposed as a single described image instead of a wall of box-drawing characters.</li>
<li>The theme button and copy button have explicit accessible names, and actions are announced through a live region.</li>
<li>Focus is always visible, motion respects <code>prefers-reduced-motion</code>, and colours follow <code>prefers-color-scheme</code>.</li>
</ul>
</article></main></div>
<div id="sr-status" class="sr-only" role="status" aria-live="polite"></div>
<script>${JS}</script>
</body>
</html>
`;
writeFileSync(`${OUTDIR}/index.html`, indexHtml, 'utf8');
console.log(`OK  index.html (${rendered.length} documents)`);
