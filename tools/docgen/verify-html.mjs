// Verify the generated HTML: structure, anchors, and accessibility invariants.
// Exit 0 when every page passes, 1 otherwise.
import { readFileSync, readdirSync } from 'node:fs';
import { dirname, resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const OUT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..', 'html');

const CHECKS = [
  ['skip link',            h => /class="skip"[^>]*href="#content"/.test(h)],
  ['banner landmark',      h => /<header class="topbar"/.test(h)],
  ['nav labelled',         h => /<nav\b[^>]*aria-label=/.test(h)],
  ['main labelled',        h => /<main id="content"[^>]*aria-label=/.test(h)],
  ['live region',          h => /id="sr-status"[^>]*role="status"[^>]*aria-live="polite"/.test(h)],
  ['theme button named',   h => /id="theme"[^>]*>[^<]*Theme/.test(h)],
  ['focus-visible style',  h => /:focus-visible\{/.test(h)],
  ['reduced-motion',       h => /prefers-reduced-motion/.test(h)],
  ['color-scheme meta',    h => /<meta name="color-scheme"/.test(h)],
  ['single h1',            h => (h.match(/<h1[\s>]/g) || []).length === 1],
  ['no h5/h6',             h => !/<h[56][\s>]/.test(h)],
  ['tables captioned',     h => {
      const tables = (h.match(/<table>/g) || []).length;
      const caps = (h.match(/<caption/g) || []).length;
      return tables === caps;
    }],
  ['th has scope',         h => !/<th(?! scope=)[ >]/.test(h)],
  ['img role has label',   h => {
      for (const m of h.matchAll(/role="img"([^>]*)>/g)) {
        if (!/aria-label="[^"]+"/.test(m[1])) return false;
      }
      return true;
    }],
  ['balanced pre',         h => (h.match(/<pre[\s>]/g) || []).length === (h.match(/<\/pre>/g) || []).length],
  ['balanced table',       h => (h.match(/<table>/g) || []).length === (h.match(/<\/table>/g) || []).length],
  ['no mojibake',          h => !/Ã|â€|�/.test(h)],
];

let failed = 0;
for (const f of readdirSync(OUT).filter(x => x.endsWith('.html')).sort()) {
  const html = readFileSync(`${OUT}/${f}`, 'utf8');
  const problems = [];

  // anchors
  const ids = new Set([...html.matchAll(/\sid="([^"]+)"/g)].map(m => m[1]));
  const anchors = [...html.matchAll(/href="#([^"]+)"/g)].map(m => m[1]);
  const broken = [...new Set(anchors)].filter(a => !ids.has(a));
  if (broken.length) problems.push(`broken anchors: ${broken.join(', ')}`);

  for (const [name, fn] of CHECKS) {
    let ok = false;
    try { ok = fn(html); } catch { ok = false; }
    if (!ok) problems.push(name);
  }

  if (problems.length) {
    failed++;
    console.log(`FAIL ${f}: ${problems.join('; ')}`);
  } else {
    const stats = {
      pre: (html.match(/<pre[\s>]/g) || []).length,
      table: (html.match(/<table>/g) || []).length,
      img: (html.match(/role="img"/g) || []).length,
      h: (html.match(/<h[1-6][\s>]/g) || []).length,
    };
    console.log(`PASS ${f}  headings=${stats.h} pre=${stats.pre} tables=${stats.table} diagrams=${stats.img} ids=${ids.size} anchors=${anchors.length}`);
  }
}
console.log(failed ? `\n${failed} page(s) failed` : '\nall pages passed');
process.exit(failed ? 1 : 0);
