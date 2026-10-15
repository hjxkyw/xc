// The xtpl extension: xc's checks as diagnostics, and a command that compiles
// the file. The highlighting is the grammar in syntaxes/, which needs no code.
//
// xc -- the C++ xc -- runs as it does from a shell, 'xc --check file.xtpl',
// on the file as saved: a source is windows-1252, and xc reads the bytes on
// disk. The settings under 'xtpl.xc' say where xc is and what to give it.

'use strict';

const vscode = require('vscode');
const path = require('path');
const fs = require('fs');
const { execFile } = require('child_process');
const { parseXcOutput } = require('./xcoutput');

let diagnostics;
let output;

// Where CMake leaves xc in a clone of xc: cpp/build, or a configuration's
// folder under it (Visual Studio's generators).
const BUILT = [
  ['cpp', 'build', 'xc'],
  ['cpp', 'build', 'xc.exe'],
  ['cpp', 'build', 'Release', 'xc.exe'],
  ['cpp', 'build', 'Debug', 'xc.exe'],
];

function isFile(p)
{
  try
  {
    return fs.statSync(p).isFile();
  }
  catch (e)
  {
    return false;
  }
}

// Where xc is: the setting; else xc built in a folder of the workspace; else
// xc on the PATH.
function xcPath()
{
  const given = vscode.workspace.getConfiguration('xtpl.xc').get('path');
  if (given)
  {
    return given;
  }
  for (const folder of vscode.workspace.workspaceFolders || [])
  {
    for (const parts of BUILT)
    {
      const candidate = path.join(folder.uri.fsPath, ...parts);
      if (isFile(candidate))
      {
        return candidate;
      }
    }
  }
  return process.platform === 'win32' ? 'xc.exe' : 'xc';
}

// The arguments for xc, before the file.
function xcOptions()
{
  const cfg = vscode.workspace.getConfiguration('xtpl.xc');
  const options = [];
  const includes = cfg.get('includes');
  if (includes)
  {
    options.push('--includes=' + includes);
  }
  const dictionary = cfg.get('dictionary');
  if (dictionary)
  {
    options.push('--dict', dictionary);
  }
  return options;
}

// Runs xc on a file; calls back with what it printed, both streams. It runs
// in the file's workspace folder, so that the settings' paths may be relative
// to it.
function runXc(args, file, done)
{
  const xc = xcPath();
  const folder = vscode.workspace.getWorkspaceFolder(vscode.Uri.file(file));
  const cwd = folder ? folder.uri.fsPath : path.dirname(file);
  const all = [...args, file];
  output.appendLine(`$ ${xc} ${all.join(' ')}`);
  execFile(xc, all, { cwd, timeout: 60000, maxBuffer: 16 * 1024 * 1024 }, (error, stdout, stderr) =>
  {
    const said = (stdout || '') + (stderr || '');
    output.append(said);
    if (error && (error.code === 'ENOENT' || error.code === 'EACCES'))
    {
      vscode.window.showErrorMessage(
        `xtpl: xc was not found at '${xc}'. Build it (cpp/build), or set 'xtpl.xc.path' to the program.`);
      return;
    }
    done(said);
  });
}

// xc's messages about a document, as its diagnostics.
function check(document)
{
  if (document.languageId !== 'xtpl' || document.uri.scheme !== 'file')
  {
    return;
  }
  const file = document.uri.fsPath;
  runXc(['--check', ...xcOptions()], file, (said) =>
  {
    const found = parseXcOutput(said, file).map((m) =>
    {
      const line = Math.max(0, Math.min(m.line - 1, document.lineCount - 1));
      const text = document.lineAt(line).text;
      const start = text.length - text.trimStart().length;
      const range = new vscode.Range(line, m.line > 0 ? start : 0, line, text.length);
      const d = new vscode.Diagnostic(range, m.message,
        m.warning ? vscode.DiagnosticSeverity.Warning : vscode.DiagnosticSeverity.Error);
      d.source = 'xc';
      return d;
    });
    diagnostics.set(document.uri, found);
  });
}

function activate(context)
{
  diagnostics = vscode.languages.createDiagnosticCollection('xc');
  output = vscode.window.createOutputChannel('xc');
  context.subscriptions.push(diagnostics, output);

  const onSave = () => vscode.workspace.getConfiguration('xtpl.xc').get('checkOnSave');
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((d) => { if (onSave()) check(d); }),
    vscode.workspace.onDidOpenTextDocument((d) => { if (onSave()) check(d); }),
    vscode.workspace.onDidCloseTextDocument((d) => diagnostics.delete(d.uri)),

    vscode.commands.registerCommand('xtpl.check', () =>
    {
      const editor = vscode.window.activeTextEditor;
      if (editor)
      {
        editor.document.save().then(() => check(editor.document));
      }
    }),

    vscode.commands.registerCommand('xtpl.compile', () =>
    {
      const editor = vscode.window.activeTextEditor;
      if (!editor || editor.document.languageId !== 'xtpl')
      {
        return;
      }
      const document = editor.document;
      document.save().then(() =>
      {
        const file = document.uri.fsPath;
        runXc(xcOptions(), file, (said) =>
        {
          const tlpp = file.replace(/\.[^./\\]*$/, '') + '.tlpp';
          if (said.includes(' -> '))
          {
            vscode.window.showInformationMessage(`xtpl: ${path.basename(file)} -> ${path.basename(tlpp)}`);
          }
          else
          {
            output.show(true);
            vscode.window.showErrorMessage(`xtpl: ${path.basename(file)} did not compile -- see the xc output.`);
          }
          check(document);
        });
      });
    })
  );

  for (const document of vscode.workspace.textDocuments)
  {
    if (onSave())
    {
      check(document);
    }
  }
}

function deactivate()
{
}

module.exports = { activate, deactivate };
