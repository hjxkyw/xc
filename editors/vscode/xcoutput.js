// What 'xc --check' says about a file, as diagnostics: one per message, with
// its line and whether it is a warning. Kept apart from extension.js, which
// needs VS Code, so that a plain 'node' can test it.
//
// bin/xc names the file as it was given, then the line, then the message:
//
//   /path/a.xtpl:12: warning: 'cX' is assigned but never read
//   /path/a.xtpl:7: 'nIn' is out of scope here (block local declared on line 3).
//   /path/a.xtpl: the file ends inside a block that was never closed
//   /path/a.xtpl: ok
//
// The path is matched as given, not split at a ':' -- 'D:\src\a.xtpl' has one.

'use strict';

// The messages for $file in xc's output, in order: {line, warning, message},
// the line from 1, or 0 when the message names none.
function parseXcOutput(text, file)
{
  const found = [];
  for (const raw of text.split(/\r?\n/))
  {
    const line = raw.trimEnd();
    if (!line.startsWith(file))
    {
      continue;
    }
    const rest = line.slice(file.length);
    let m = /^:(\d+): (warning: )?(.*)$/.exec(rest);
    if (m)
    {
      found.push({ line: Number(m[1]), warning: Boolean(m[2]), message: m[3] });
      continue;
    }
    m = /^: (.*)$/.exec(rest);
    if (m && m[1] !== 'ok' && !m[1].startsWith('-> '))
    {
      found.push({ line: 0, warning: false, message: m[1] });
    }
  }
  return found;
}

module.exports = { parseXcOutput };
