# xmanig.dictations

User-owned Omarchy/Quickshell plugin for Voxtype push-to-talk history. Stores transcript text locally; no audio is retained by this plugin. Installed without changing packaged Omarchy files.

## Install

Requires Omarchy's Quickshell plugin system, Python 3 with SQLite FTS5, Voxtype with post-processing support, and `wl-copy` for clipboard actions.

```sh
omarchy plugin add https://github.com/xmanig/xmanig-omarchy-dictations --enable
omarchy bar move xmanig.dictations --section right
omarchy restart shell
```

Installing the bar plugin does not automatically enable transcript capture. Add this to your Voxtype configuration (merge with an existing post-processing pipeline rather than declaring the table twice):

```toml
[output.post_process]
command = 'python3 "$HOME/.config/omarchy/plugins/xmanig.dictations/bin/dictations.py" capture'
timeout_ms = 2000
```

Restart the idle Voxtype daemon with `systemctl --user restart voxtype`. History starts with subsequent dictations; previous dictations are not imported.

An optional Omarchy Lua keybinding is:

```lua
o.bind("SUPER + ALT + H", "Dictation history", "omarchy-shell xmanig.dictations toggle")
```

Check for a conflicting binding before adding it. Summaries default to the authenticated Codex CLI; install/sign in to Codex or configure another provider in Settings.

## Use

- **Super + Alt + H** toggles the inbox. The microphone button in the right bar does the same; right-click opens expanded history.
- **Open history** expands to search, date/collection filters, multi-selection, a transcript reader, summaries, and export. **Escape** closes the panel or cancels a deletion confirmation.
- Right Alt push-to-talk remains unchanged. The status line and bar icon follow Voxtype's runtime state.
- **Pause capture** stops saving new history, not Voxtype recording or typing. Resume from the same button.
- **Settings → Create collection** creates an idea collection or named agent session. **Capture into** chooses the collection for future entries. Select existing entries and **Move** to organize them afterward. Session names are explicit labels, not automatic links to a terminal or agent process.
- Select checkboxes, choose **Agent handoff**, **Ideas**, or **Daily digest**, then press **Summarize**. Only selected records (text, source IDs, timestamps, collection labels) are supplied to the provider. A daily digest summarizes the selection, not automatically every note from that day; use the date filter first.
- **Saved summaries** shows original source snapshots with each summary. Copy the summary alone or export Markdown including its sources.
- **Copy Markdown** exports the current selection/summary to the clipboard. **Save file** creates a new private file at the entered absolute path (`~` is supported). Existing files are never overwritten.

## Providers and privacy

Capture, storage, and search do not contact any model. Summarization runs only on an explicit click.

The installed default is **Codex / ChatGPT cloud**, using the existing authenticated `codex` CLI. It runs from an empty temporary directory with user configuration/rules ignored, session persistence disabled, read-only sandboxing, web search disabled, and shell/browser/integration tools disabled. Model output is saved as a summary, never substituted for the original dictation. Provider failures are displayed rather than replaced with a fake summary.

Other providers can be selected in Settings:

- **Ollama:** requires a running server and an installed model. Blank endpoint uses `http://127.0.0.1:11434`; blank model uses `llama3.2`. No server or model was installed as part of this plugin.
- **OpenAI-compatible:** set a model and optionally the API base URL (default `https://api.openai.com/v1`). Supply the **environment-variable name**, normally `OPENAI_API_KEY`, never the secret key in the settings field. That variable must be inherited by the running Omarchy shell. HTTP redirects are rejected rather than forwarding notes or credentials elsewhere.

Retention defaults to **0: keep forever**. A positive retention period deletes expired entries and summaries/source snapshots when capture or refresh runs. A summary expires if any source snapshot exceeds retention, even if the summary itself is newer. Changing retention can immediately remove old data.

Deleting an inbox entry does **not** delete saved summaries that used it: those retain explicit snapshots for traceability, as disclosed in the confirmation. Delete the relevant saved summaries too when removing their retained text. Exported files and clipboard contents are independent copies and are not removed by database retention. The local database is permission-restricted, not independently encrypted; filesystem backups can retain previous versions.

## Installation layout

- Source repository: `~/repos/xmanig-omarchy-dictations/`; installed plugin: `~/.config/omarchy/plugins/xmanig.dictations/` (symlink to the repository).
- Database/settings: `${XDG_DATA_HOME:-~/.local/share}/omarchy/dictations/dictations.sqlite3`
- Private data directory: mode `0700`; database and exports: mode `0600`.
- Voxtype capture hook: `[output.post_process]` in `~/.config/voxtype/config.toml` invokes `/usr/bin/python3 .../bin/dictations.py capture`, timeout 2000 ms.
- Bar entry: `xmanig.dictations` in `~/.config/omarchy/shell.json`.
- Shortcut: `~/.config/hypr/bindings.lua`.

The panel root forwards the bar button's implicit width and height so the bar allocates a visible, clickable icon slot. Keep those bindings when modifying the widget.

The open panel refreshes every five seconds. After initial loading, state reads run silently without disabling controls or inserting a progress row. Unchanged collections, entries, summaries, selections, and reader records retain their existing model objects. Actions clicked during a state read are queued until it completes; explicit mutations still display progress. This prevents idle polling from shifting the layout or rebuilding unchanged delegates.

The capture helper writes the exact input bytes back to stdout, including when storage fails or capture is paused. Storage errors are reported generically on stderr without echoing transcript text. Voxtype also falls back to the original transcript when its processing command fails. There is no LLM in this path.

Voxtype's `transcribe FILE` CLI prints the recognized transcript directly and does not invoke its desktop output hook; push-to-talk history is captured through the daemon output path.

The three modified config files have `.before-dictations` backups (numbered if a backup already existed). To disable the integration, remove the added Voxtype post-processing table, the `xmanig.dictations` bar entry, and the added shortcut, then restart Voxtype and reload Hyprland. Preserve any later unrelated config changes rather than blindly restoring an old backup. The database remains until explicitly removed.

## Backend interface and verification

`bin/dictations.py capture` is a stdin/stdout byte-preserving filter. `bin/dictations.py rpc` reads one JSON object from stdin and emits one JSON object; errors use `{ "ok": false, "error": "..." }` and exit status 1. Run `--help` for actions and storage details. `DICTATIONS_DATA_DIR` isolates storage for checks.

Regression suite:

```sh
cd ~/repos/xmanig-omarchy-dictations
/usr/bin/python3 -B -m unittest discover -s tests -v
```

Verified during installation: exact-byte passthrough, failed-storage passthrough, pause/resume, literal FTS search, collections/assignment, selected-only real Codex summaries, private Markdown exports, snapshot deletion/retention, native compact/expanded/history/settings/summary surfaces, UI search/selection/summary/export/deletion, live recording/cancellation indicator, and the actual Super+Alt+H compositor shortcut. Temporary UI entries and summaries were removed. Ollama and OpenAI-compatible network providers were not exercised against real servers.
