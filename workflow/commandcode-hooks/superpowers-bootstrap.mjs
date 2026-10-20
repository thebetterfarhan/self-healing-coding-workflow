// SessionStart hook — inject the Superpowers bootstrap so the agent reaches for a
// skill before acting. Skills installed with: cmdc skills add obra/superpowers -s <name> -g
// Source: https://github.com/obra/superpowers (MIT). No-ops if the skill is gone.
import { readFileSync } from 'node:fs';
import { homedir } from 'node:os';
import { join } from 'node:path';

let skill = '';
try {
  skill = readFileSync(join(homedir(), '.commandcode', 'skills', 'using-superpowers', 'SKILL.md'), 'utf8');
} catch {
  process.exit(0); // not installed: inject nothing, never block the session
}

// Drop the YAML frontmatter, keep the instructions.
const body = skill.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n/, '').trim();

const mapping = [
  'Superpowers is installed (obra/superpowers). In Command Code:',
  'invoke a skill with the activate_skill tool, or type /skill:<name>;',
  'dispatch subagents with the agent tool (subagent_type: explore | general | plan);',
  'track work with todo_write. The bootstrap below is mandatory.',
].join(' ');

process.stdout.write(JSON.stringify({
  hookSpecificOutput: {
    hookEventName: 'SessionStart',
    additionalContext: `${mapping}\n\n${body}`,
  },
}));
