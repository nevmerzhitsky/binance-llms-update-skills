---
name: binance-llms-update
description: Download or refresh Binance API documentation prepared for LLM use in an operator-specified directory. Use when the operator asks to download, update, refresh, or synchronize llms.txt and llms-full.txt from the official Binance Developer Documentation endpoints.
license: "MIT"
compatibility: "Windows 11 with Windows PowerShell 5.1+"
metadata:
  author: "nevmerzhitsky"
  version: "1.0"
---

# Binance API Documentation Update

Update Binance documentation prepared for LLM use in a directory explicitly selected by the operator.

## Required Input

The operator must provide the exact absolute path to the directory that contains or will contain `llms.txt` and `llms-full.txt`.

Before running any command:

1. If the operator has not supplied the target directory, stop and ask for it.
2. If the supplied path is relative, stop and ask for its absolute form. Do not resolve it against the current working directory, project root, skill installation, or agent configuration.
3. Use the supplied directory exactly. It may already exist or may need to be created.

## Fixed Sources And File Names

Use only these source-to-file mappings inside the operator-supplied directory:

| Official source                                        | Target file                        |
|--------------------------------------------------------|------------------------------------|
| `https://developers.binance.com/en/docs/llms.txt`      | `<target-directory>\llms.txt`      |
| `https://developers.binance.com/en/docs/llms-full.txt` | `<target-directory>\llms-full.txt` |

Do not accept replacement URLs, use mirrors, change the two file names, or write downloaded content outside the supplied directory. The updater must reject redirects outside the official HTTPS host.

## Requirements

- Run on Windows 11 with Windows PowerShell 5.1 or newer.
- Do not install Python, `requests`, PowerShell modules, package managers, or other dependencies.
- Resolve the bundled updater relative to this `SKILL.md` file's actual installation directory. Do not assume that the skill is installed under `.agents/`, `.opencode/`, a project, a user profile, or any particular agent's configuration directory.

## Procedure

1. Resolve and verify `<skill-directory>\scripts\Update-BinanceLlmsDocs.ps1`, where `<skill-directory>` is the directory containing this `SKILL.md`.
2. Run the updater from any working directory, passing the operator-supplied absolute directory explicitly:

```powershell
powershell.exe -NoLogo -NoProfile -File "<skill-directory>\scripts\Update-BinanceLlmsDocs.ps1" -TargetDirectory "<operator-supplied-absolute-directory>"
```

3. Treat a nonzero exit code as a failed update. Report the error and do not manually overwrite either documentation file.
4. Report the updater's per-file `updated` or `unchanged` result and its final completion message.

## Safety Contract

The bundled updater is responsible for all network and filesystem changes. It must:

- use the fixed official HTTPS URLs and verify every redirect before following it;
- require an explicit absolute target directory and create it when it does not exist;
- apply finite request timeouts and retry only transient network or HTTP failures;
- stream responses with per-file size limits instead of buffering an unbounded response;
- require HTTP 200, `text/plain`, strict UTF-8, and Binance-specific document markers;
- download and validate both files before replacing either existing file;
- atomically replace each changed target and roll back committed replacements if the commit fails;
- leave existing files untouched when download or validation fails;
- avoid rewriting unchanged files;
- clean up staged and backup files after success or failure;
- never execute downloaded content or print it to the terminal.

## Failure Handling

If the updater fails, preserve the error text in the report. Do not bypass certificate validation, relax content validation, increase size limits, change URLs, or replace files with a partial response to force completion. Leave the last validated local copies in place and surface the failure to the operator.
