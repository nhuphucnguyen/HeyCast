# HeyCast Notes — plan

Goal: a fast place to throw short thoughts and new words without leaving the
current task, then resolve or review them later — by hand or with an AI.
Native Swift only. It fits the extension system (`Sources/HeyCast/Extensions`).

## 1. What Raycast ships (2.12.1, inspected from the installed bundle)

Notes itself is **free** in Raycast. I found no note-count limit, but the
search only covered strings.
Pro sells the things *around* notes:

| Pro-gated product (`gatedProduct`) | Relevance to notes |
|---|---|
| `cloud_sync` | "Your Notes and Chats on your iPhone, and across computers" |
| `ai_chat` | includes **Ask Raycast Notes** (`@raycast-notes` AI extension) |
| `dictation` | **Dictate to Note** |
| `scheduled_export` | automatic backup of settings + data |
| `translator`, `custom_themes`, `custom_window_management`, `clipboard_retention` | not notes |

Notes features found in the shipped strings and IPC (`backend.notes.*`):

- Commands: Create Note, Search Notes, Browse Notes, Toggle Notes window,
  Save to Notes, Ask Raycast Notes, Dictate to Note, Import from Classic.
- A floating Notes window (`notes-window.html`). It can hide while the
  screen is being recorded.
- Pin/unpin with reordering, pinned notes shown in root search, Duplicate,
  Copy Note As…, Find in Note, linked notes, images and attachments.
- Soft delete: "Recently Deleted" with restore and permanent delete, plus
  purging old deleted notes.
- It remembers the current note, the caret position and the last-accessed
  time.
- AI tools that let an agent work with notes: `NotesCreateNoteTool`,
  `NotesReadNoteTool`, `NotesSearchNotesTool`, `NotesGetCurrentNoteTool`.

Storage, from a Rust data core holding SQLite (`data/core/src/notes/repository.rs`):

```sql
CREATE TABLE notes (
  id TEXT PRIMARY KEY DEFAULT(ULID()),   -- migrated from INTEGER (V25) for sync
  title TEXT, text TEXT NOT NULL, raw_content TEXT,
  pinned REAL,                           -- fractional index for ordering
  created_at, updated_at, deleted_at,    -- deleted_at = tombstone (V26)
  last_accessed_at                       -- (V27), caret_position (V52)
) STRICT, WITHOUT ROWID;
```

Sync (`V32__migrate_notes_to_cloudsync`) uses SQLite triggers
(`cloudsync_trg_*`) feeding an `entities` change log.

Takeaways: string IDs, tombstones and timestamps exist so that sync is
possible. AI access is a small set of tools: create, read, search and
current. We need the same, but with an MCP server so any AI can use them.

Where this comes from: string and schema extraction from
`Raycast.app/.../frontend/*.js` and `backend/data.darwin-arm64.node`.
REA JS graph `ev_5092fc39…` (partial coverage; it isn't Electron, so no IPC
graph). Nothing was executed, so runtime gating is not observed.

## 2. What HeyCast Notes is (scope)

Three kinds of item in one store, because the intent at capture time
differs:

| Kind | Capture | Later |
|---|---|---|
| `inbox` | a thought or todo thrown in mid-task | resolve / turn into a note / delete; AI triage |
| `note` | longer markdown note | edit, pin, search |
| `word` | new English word or phrase (+ the sentence it was seen in) | end-of-day review, spaced repetition |

## 3. Data model — `NotesStore` (system libsqlite3, like `ClipboardStore`)

`~/.config/heycast/notes.db` (`Config.directory`), WAL mode so the MCP
process can read it while the app runs.

```sql
CREATE TABLE items (
  id TEXT PRIMARY KEY,              -- UUIDv7 (time-sortable), sync-safe
  kind TEXT NOT NULL CHECK(kind IN ('inbox','note','word')),
  title TEXT,                       -- word: the word itself
  body TEXT NOT NULL DEFAULT '',    -- markdown; word: definition/notes
  context TEXT,                     -- JSON: source app, window title, URL, example sentence
  status TEXT NOT NULL DEFAULT 'open' CHECK(status IN ('open','resolved','archived')),
  tags TEXT NOT NULL DEFAULT '',
  pinned REAL,                      -- fractional index (Raycast-style)
  created_at INTEGER NOT NULL, updated_at INTEGER NOT NULL,
  deleted_at INTEGER,               -- tombstone; purge after 30 days
  -- word review (SM-2 lite)
  due_at INTEGER, interval_days REAL, ease REAL, reviews INTEGER DEFAULT 0,
  -- sync
  rev INTEGER NOT NULL DEFAULT 0, dirty INTEGER NOT NULL DEFAULT 1
);
CREATE VIRTUAL TABLE items_fts USING fts5(title, body, content='items', content_rowid=...);
```

Put `NotesStore` and the models in a new **library target `NotesCore`**.
The app and the MCP executable (step 6) then share the same code.

## 4. Capture (the most important part: under 2 seconds, then back to work)

- **Root search prefix** (a `ResultProvider`, `.search` phase):
  - `;fix flaky login test` → Enter saves to the inbox, hides the launcher,
    and shows a short HUD. ⌘Enter saves and keeps the launcher open.
  - `w serendipity` → saves a word. Text after `—` becomes the example
    sentence.
  - `n ` opens a new full note on the Notes page.
  - Make the prefixes configurable in `Config`.
- **Auto context**: the frontmost app at capture (`ctx.targetApplication`),
  the window title, and the browser URL (AppleScript for Safari/Chrome/Arc).
  This answers "what was I doing when I wrote this?" when you resolve it
  later.
- **Global hotkey "Quick Capture"**: opens the launcher already in capture
  mode (reuse `HotKeyManager`).
- **Capture the selection**: a command that takes the selected text (⌘C
  round-trip) or the clipboard and saves it as inbox or word.
- Pinned notes and open inbox items show up in root search.

## 5. Notes page (an `ExtensionPage`)

- Tabs: **Inbox** (open) · **Words** · **Notes** · **Resolved** · **Recently Deleted**.
- List + detail split like the Clipboard page. The detail is an editable
  markdown `NSTextView` with a `MarkdownView` preview toggle.
- ⌘K actions: Resolve, Convert to Note, Pin/Unpin, Copy, Paste to App, Ask
  Agent, Delete/Restore, Open Source URL.
- **Review Words**: a flashcard mode (word → reveal definition/example →
  Again / Good / Easy), scheduled with SM-2 lite.
- **End-of-day reminder**: a configurable time (e.g. 18:00) sends a
  notification through `NotificationService`, such as "5 words to review ·
  3 inbox items open". Clicking it opens the right tab.

## 6. AI

Two directions:

**a) HeyCast → AI (reuse `AssistantService` / configured agents)**
- *Triage inbox*: send the open inbox items with their context. Ask for
  groups, a suggested next action and a priority. The answer becomes a
  pinned note, and actions can update items.
- *Enrich word*: fill in IPA, a definition, 2 examples and collocations.
  Run it automatically when a word is captured (optional, fire-and-forget
  like the Assistant).

**b) AI → HeyCast: MCP server (native Swift)**
- New executable target `heycast-mcp` (depends on `NotesCore`). It speaks
  MCP over **stdio**, so Claude Code and Claude Desktop can launch it:
  `claude mcp add heycast -- /Applications/HeyCast.app/Contents/MacOS/heycast-mcp`.
- Use the official `modelcontextprotocol/swift-sdk`, or hand-roll JSON-RPC
  (only `initialize`, `tools/list` and `tools/call` are needed).
- Tools, matching Raycast's set plus triage:
  - `notes_list(kind?, status?, since?)`, `notes_search(query)`, `notes_get(id)`
  - `notes_create(kind, title?, body)`, `notes_update(id, body?, status?, tags?)`
  - `notes_resolve(id, resolution)`: appends the resolution and marks it resolved
  - `words_due()`, `words_enrich(id, definition, examples)`
- Writes come from another process, so the app watches the DB (a
  `DispatchSource` on the WAL file, or a `PRAGMA data_version` poll when
  the page is visible) and reloads.
- Example workflow: in Claude Code, "go through my HeyCast inbox and
  resolve what you can".

## 7. Sync (later; the schema is ready from day 1)

UUID ids + `updated_at` + `rev` + `deleted_at` tombstones + `dirty` flag
are enough for a simple, reliable model: **per-row last-writer-wins** using
a hybrid logical clock. For short notes that is good enough. Raycast's
CRDT-trigger approach is overkill here.

Options, simplest first:
1. **Folder sync**: export each item as a markdown file with front matter
   to a chosen folder (iCloud Drive / Syncthing / git repo), and import
   changes back. No server needed, and Obsidian-friendly.
2. **Own server**: a small Swift (Hummingbird/Vapor) service with SQLite or
   Postgres, `POST /sync {since, changes[]} → {changes[], cursor}`, and
   token auth in Keychain. The same server can host **MCP over HTTP**, so a
   phone or cloud AI agent can reach your notes when the Mac is asleep.
3. CloudKit: native, but needs a signed app with iCloud entitlements, which
   doesn't fit the current `make_app.sh` build.

Recommendation: start with 1 and design the sync protocol for 2.

## 8. Phases

1. **Core**: `NotesCore` target, `NotesStore` + FTS, `NotesExtension`
   (capture prefixes, root-search rows), the Notes page with Inbox/Notes,
   resolve/delete/restore.
2. **Words + review**: word capture, flashcard review, SM-2, the
   end-of-day notification.
3. **AI out**: triage inbox, enrich words through `AssistantService`.
4. **MCP**: the `heycast-mcp` stdio executable, packaged in the app
   bundle, plus a doc snippet for `claude mcp add`.
5. **Sync**: folder export/import → server + remote MCP.

Each phase can ship by itself. Phase 1 alone replaces the "quick throw" use
case.

## Open questions

- Do you want capture prefixes (`;`, `w `) or a dedicated hotkey panel, or
  both?
- Should word enrichment run automatically on capture, or only on demand
  (it costs tokens)?
- Server: is a self-hosted box available, or should folder sync come first?
