// xc's output read as diagnostics (xcoutput.js): what xc prints, as it
// prints it, on Linux and on Windows.

'use strict';

const assert = require('assert');
const { parseXcOutput } = require('../xcoutput');

let ok = 0;
let total = 0;
function check(what, test)
{
  total++;
  try
  {
    test();
    ok++;
    console.log('  ok    ' + what);
  }
  catch (e)
  {
    console.log('  FAIL  ' + what + '\n    ' + e.message);
  }
}

check('a warning and an error, with their lines', () =>
{
  const f = '/src/a.xtpl';
  const said = `${f}:12: warning: 'cX' is assigned but never read\n`
             + `${f}:7: 'nIn' is out of scope here (block local declared on line 3).\n`;
  assert.deepStrictEqual(parseXcOutput(said, f), [
    { line: 12, warning: true, message: "'cX' is assigned but never read" },
    { line: 7, warning: false, message: "'nIn' is out of scope here (block local declared on line 3)." },
  ]);
});

check("a message with no line; 'ok' and a compile's '->' are none", () =>
{
  const f = '/src/a.xtpl';
  const said = `${f}: the file ends inside a block that was never closed\n${f}: ok\n${f} -> /src/a.tlpp\n`;
  assert.deepStrictEqual(parseXcOutput(said, f), [
    { line: 0, warning: false, message: 'the file ends inside a block that was never closed' },
  ]);
});

check("a Windows path, its drive's ':' and CRLF line ends", () =>
{
  const f = 'D:\\src\\a.xtpl';
  const said = `${f}:3: cannot parse this line: x := (1 +\r\n${f}:5: warning: 'n' is not declared\r\n`;
  assert.deepStrictEqual(parseXcOutput(said, f), [
    { line: 3, warning: false, message: 'cannot parse this line: x := (1 +' },
    { line: 5, warning: true, message: "'n' is not declared" },
  ]);
});

check("another file's messages are not this one's", () =>
{
  const said = '/src/b.xtpl:3: warning: x\n/src/a.xtpl:4: warning: y\nxc: 2 files, 2 checked ok\n';
  assert.deepStrictEqual(parseXcOutput(said, '/src/a.xtpl'), [{ line: 4, warning: true, message: 'y' }]);
});

console.log(`\n  ${ok} of ${total}`);
process.exit(ok === total ? 0 : 1);
