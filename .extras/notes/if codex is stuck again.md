## Codex sidebar stuck on logo

**Fix: downgrade Codex temporarily**

1. Open Extensions → Codex → gear icon.
2. Disable **Auto Update** temporarily.
3. Choose **Install Another Version...**
4. Install the most recent older version that worked. (openai.chatgpt@26.527.60818)
5. Fully restart VS Code. (File → Exit or Ctrl+Q)

Or:

```bash
code --install-extension openai.chatgpt@VERSION --force
```

Verify:

```bash
code --list-extensions --show-versions | grep -i openai
```

Do **not** clear `~/.codex/auth.json`, sessions, databases, or configuration when `codex doctor` is healthy.

After a newer Codex version is released, update and test again. Re-enable Auto Update once the problem is fixed.

### Diagnostics:

```bash
code --version
code --list-extensions --show-versions | grep -i openai
```

Run diagnostics using the Codex binary bundled with the extension:

```bash
CODEX_BIN="$(
  find "$HOME/.vscode/extensions" "$HOME/.vscode-server/extensions" \
    -type f -path '*/openai.chatgpt-*/bin/*/codex' 2>/dev/null |
  sort -V | tail -n 1
)"

"$CODEX_BIN" doctor --summary
```

If `doctor` is healthy but the Codex sidebar/settings still show only the logo, it is probably an extension UI/webview regression.
