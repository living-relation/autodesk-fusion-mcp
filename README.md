# Autodesk Fusion MCP Server

Standalone MCP server that runs inside Autodesk Fusion (formerly Autodesk
Fusion 360) as an add-in. AI agents connect over **Streamable HTTP** -- the
current MCP transport specification -- with no external proxy, middleware, or
dependencies required.

## Highlights

- **Streamable HTTP transport** -- implements the MCP Streamable HTTP spec
  natively; no legacy SSE polling or sidecar servers.
- **Protocol compatibility** -- supports stateless `2026-07-28` requests and
  retains `2025-11-25`, `2025-06-18`, and `2025-03-26` clients on the same
  endpoint. See [protocol behavior and compatibility](docs/mcp-protocol-compatibility.md).
- **Zero external dependencies** -- uses only Python's standard library and
  the Fusion SDK (`adsk.*`).
- **Thread-safe bridge** -- HTTP requests are relayed to Fusion's main thread
  via a Custom Event / work-queue dispatcher, preventing crashes.
- **14 dedicated MCP tools** -- each with a clean, focused schema for better
  LLM tool selection.

## Supported Platforms

- Windows
- Mac OS

## How this add-in is installed

**AutodeskFusionMCP is junctioned straight to the repo clone**, so a `git pull` updates what Fusion loads. Fusion's AddIns entry must be named exactly `AutodeskFusionMCP` and must point at the repo root (this add-in's files live at the root, not in a subfolder).

Fusion does not pick up new code until the add-in restarts: restart Fusion, or press **Shift+S**, open **Add-Ins**, and **Stop** then **Run**.

An automatic updater (coming soon, in the workstation repo) will pull updates hourly and notify you to restart Fusion.

To create the junction on Windows, open a normal Command Prompt (not Run as administrator). `mklink /J` does not need elevation. Both paths below are absolute, so no `cd` is required. Run:

```
mklink /J "%APPDATA%\Autodesk\Autodesk Fusion 360\API\AddIns\AutodeskFusionMCP" "<path-to-this-clone>"
```

Replace `<path-to-this-clone>` with this repo's clone path on that PC. The active-folder path differs per PC. If a copied `AutodeskFusionMCP` folder already exists in AddIns, rename or remove it first so the junction can be created.

### Daily sync from upstream

The **Sync upstream** action runs every day, and you can also run it from the Actions tab. It brings [frankhommers/autodesk-fusion-mcp](https://github.com/frankhommers/autodesk-fusion-mcp) `main` into this fork's `main`. The PCs that fast-forward this repo pick that up on their next hourly pull.

The action only moves `main` forward. It fast-forwards when it can. If this fork has its own commits, it adds a normal merge commit. It does not rewrite commits that are already on `main`.

If the merge has conflicts, the action leaves `main` unchanged and the run fails. The log lists the conflicted files. When Issues are enabled on this fork, it also opens or updates one issue titled **Upstream sync conflict**, and a later successful run closes that issue. Merge upstream into `main` yourself and push without `--force`. The next run continues from that push.

The action uses GitHub's default token. That token cannot push a change under `.github/workflows`. If upstream edits those files, the run fails and `main` stays as it is until a person merges that update and pushes it. If the schedule never starts, enable **Sync upstream** once on the Actions tab. If this repo is quiet for 60 days, GitHub turns the schedule off; enable the workflow again there.

## Installation

### Recommended: directory junction to a git clone (Windows)

1. Clone this repository to a folder you keep on disk. The active-folder path differs per PC.
2. Create the AddIns junction as described in [How this add-in is installed](#how-this-add-in-is-installed). Do not copy the folder into AddIns, and do not clone directly into the AddIns folder; a copy will not follow `git pull`.
3. Restart Fusion (the manifest has `runOnStartup: true`), or press **Shift+S**, open the **Add-Ins** tab, and click **Run**. After a later `git pull`, restart the add-in (**Stop**, then **Run**) or restart Fusion.
4. The server listens on `http://127.0.0.1:8765/mcp`.

### Alternative: release zip (does not follow git pull)

1. Download `AutodeskFusionMCP-v*.zip` from the
   [Releases](https://github.com/frankhommers/autodesk-fusion-mcp/releases)
   page.
2. Extract the zip into your Fusion add-ins folder:
   - **macOS:** `~/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns/`
   - **Windows:** `%APPDATA%\Autodesk\Autodesk Fusion 360\API\AddIns\`
3. Make sure the extracted folder is named `AutodeskFusionMCP` (rename it if
   the zip extracts to a different name).
4. Open Fusion, press **Shift+S**, select the **Add-Ins** tab, and run
   **AutodeskFusionMCP**.
5. The server listens on `http://127.0.0.1:8765/mcp`.

A copied zip will not update when this repo changes. Prefer the junction install above if you want `git pull` to update what Fusion loads.

### macOS: symlink to a git clone

On macOS, a symlink can serve the same role as a Windows directory junction. Open Terminal and run:

```
ln -s "<path-to-this-clone>" "$HOME/Library/Application Support/Autodesk/Autodesk Fusion 360/API/AddIns/AutodeskFusionMCP"
```

Replace `<path-to-this-clone>` with this repo's clone path on that Mac. Then start the add-in as in the Windows steps above.

## MCP Client Configuration

Add to your MCP client config (Claude Desktop, Cursor, etc.):

```json
{
  "mcpServers": {
    "autodesk-fusion-mcp": {
      "type": "http",
      "url": "http://127.0.0.1:8765/mcp"
    }
  }
}
```

## Tools

| Tool | Description |
|---|---|
| `call_autodesk_api` | Execute a generic Fusion API call via dotted path |
| `execute_python` | Run Python code inside the live Fusion session |
| `capture_viewport` | PNG capture with temporary views, transparency, solid backgrounds and cropping |
| `get_viewport` | Read camera state and viewport dimensions |
| `set_viewport` | Standard views, projection, orbit, pan, zoom, fit and camera restoration |
| `get_active_selection` | Get objects currently selected in the viewport |
| `manage_annotations` | List, claim, complete or release session-only selection annotations |
| `fetch_api_documentation` | Search Fusion API metadata via runtime introspection |
| `fetch_online_documentation` | Fetch Autodesk cloudhelp docs for a class/member |
| `fetch_design_guide` | Read the bundled design guide |
| `save_script` | Save a reusable Python script |
| `load_script` | Load a previously saved script |
| `list_scripts` | List saved scripts with metadata |
| `delete_script` | Delete a saved script |

### Generic API example

```json
{
  "api_path": "rootComponent.sketches.add",
  "args": ["rootComponent.xYConstructionPlane"],
  "remember_as": "my_sketch"
}
```

Path shortcuts: `app`, `ui`, `design`, `rootComponent`, `$stored_name`.

Constructors accepted in args: `Point3D`, `Vector3D`, `Point2D`,
`ValueInput`, `ObjectCollection`, `Matrix3D`.

### Selection example

The `get_active_selection` tool returns details of objects selected in the
viewport and stores them as `$selection_0`, `$selection_1`, etc. for use in
follow-up API calls.

### Selection annotations

Open **Selection annotations** from the Design workspace's **Utilities → Add-Ins**
panel. Select objects in Fusion, click **Capture selection**, type a
note, and click **Add**. The captured selection stays attached even when
you select something else. Shortcut: right-click a selection and choose
**Annotate selection** to open the panel with that selection already captured.
Ask your agent to process the open annotations.
Adding a note does not automatically start an agent.

Annotations are grouped by document and live only in memory. Closing a document,
stopping the add-in, or exiting Fusion discards them. Closing the palette does
not discard them; reopen it from the toolbar.

To follow geometry through edits, each captured object gets a small Fusion
attribute (a *marker*, group `autodesk-fusion-mcp`) holding only the annotation
ID. Fusion carries markers along when geometry is recomputed or split. Markers
are removed when the annotation is deleted or completed and when the add-in
stops. Adding or removing a marker is an undo step in Fusion, and markers present
when you save are stored with that version. **Remove markers from design** in
the palette removes every marker from the active design, including leftovers
from a crash or an earlier session. Objects in referenced (external) components
cannot carry markers; they are tracked in memory only.

Each captured selection shows its status after later edits:

- **ok:** unchanged.
- **changed:** still present, but its size or position differs from capture.
- **split:** divided into several pieces; the agent receives all of them.
- **missing:** consumed or deleted (for example an edge that became a fillet).
  Claiming is refused; edit the annotation and capture it again.
- **unverified:** the timeline is rolled back, so nothing can be checked.

- **Open:** editable and removable.
- **In progress:** claimed by an agent; editing and reactivation are blocked
  in both the UI and backend. The trash button still removes the row immediately.
  Removing a row does not stop or notify the client. Its existing object references
  remain usable until it completes/releases the claim; the row stays gone.
- **Completed:** retained with the agent's result. Delete it with the trash
  button, or choose **Edit / Reactivate** and save to reopen it.
- **Interrupted / failed:** released by the agent after failure/cancellation;
  retained for review, editing/reactivation or deletion.

The agent workflow uses `manage_annotations`:

1. `{"action":"list"}` returns annotations for the active document without
   claiming or consuming them.
2. `{"action":"claim","id":"…","revision":1}` atomically claims an open
   annotation and returns its `claim_token`, the current `$references` of the
   captured objects, and `warnings` for changed, split or unverified selections.
3. Work with those references in the same active document. Do not use
   `clear_context` while references are needed. Other agents must not work on
   claimed annotations.
4. `{"action":"complete","id":"…","claim_token":"…","result":"…"}` marks it
   done. On failure, cancellation or abandonment, use `"action":"release"`
   instead and explain what happened in `result`. References are removed at
   completion/release; the captured objects remain attached to the annotation.

Always complete or release a claim, including when stopping early. A lock has
**no automatic timeout**: silence does not prove the agent has stopped. If an
agent crashes before releasing, you can remove its row with the trash button.
References for a removed in-progress row are retained until the agent finishes,
the document closes, or the add-in stops.
A released annotation is not automatically retried. The user reactivates it.

Edits use revision checks, so an old UI cannot overwrite a newer annotation.
If captured geometry is missing, claiming it is rejected; edit the annotation
and capture its selection again. Annotations do not freeze geometry or prevent
ordinary modeling changes by the user or other agents.

## Architecture

```
AI agent
  |  Streamable HTTP (POST/GET/DELETE /mcp)
  v
lib/mcp_server.py           -- HTTP server (threading, stdlib only)
  |
fusion_bridge/dispatch.py   -- Custom Event queue relay
  |
fusion_bridge/operations.py -- per-tool routing
  |
fusion_bridge/selection.py  -- viewport selection reader
fusion_bridge/python_exec.py -- Python execution
fusion_bridge/viewport.py   -- camera controls and viewport capture
fusion_bridge/doc_lookup.py -- API docs introspection
fusion_bridge/script_store.py -- script CRUD
  |
adsk.core / adsk.fusion     -- Fusion 360 SDK (main thread)
```

## Testing

### Unit tests

Run the test suite (no Fusion required):

```
python3 -m unittest discover -s tests
```

CI runs these tests on every push and pull request via GitHub Actions.
Real HTTP tests cover both protocol eras, connection reuse, and cancellation
without requiring Fusion. A live Fusion/client smoke test is still needed
before releasing transport changes.

### Protocol compliance with MCP Inspector

The official [MCP Inspector](https://github.com/modelcontextprotocol/inspector)
can verify Streamable HTTP compliance against a running server.

**Against the live Fusion add-in** (port 8765):

```
npx @modelcontextprotocol/inspector --cli http://127.0.0.1:8765/mcp --transport http --method tools/list
```

**Against the standalone test server** (no Fusion required):

```
python3 test_server.py                  # starts a dummy server on port 9765
npx @modelcontextprotocol/inspector --cli http://127.0.0.1:9765/mcp --transport http --method tools/list
```

## Reporting Issues

Please report any issues on the [Issues](https://github.com/frankhommers/autodesk-fusion-mcp/issues) page.

## Author

Frank Hommers / [Initialize](https://initialize.nl)

## License

This project is licensed under the terms of the MIT license. See [LICENSE](LICENSE).

## Changelog

- v 1.6.0
  - Track annotated geometry with Fusion attribute markers (group
    `autodesk-fusion-mcp`) so annotations follow recomputes and splits
  - Report each selection as ok, changed, split, missing or unverified in the
    palette and in `manage_annotations`; claims return every piece of a split
    selection plus warnings, and refuse missing geometry
  - Remove markers on delete, completion and add-in stop; **Remove markers from
    design** purges all markers, including leftovers

- v 1.5.0
  - Add session-only selection annotations: a Fusion palette to attach notes
    to captured selections, and the `manage_annotations` tool so agents can
    list, claim, complete or release them with revision and claim-token checks
  - Right-click a selection and choose **Annotate selection** to open the
    palette with that selection already captured
  - Removing a row never aborts client work; references stay valid until the
    agent completes or releases its claim
  - Palette and About dialog prefer Fusion's Artifakt Element font

- v 1.4.1
  - Wait for Fusion's main thread before binding the MCP server; bound
    dispatcher waits and distinguish queued cancellation from running work
  - Scope legacy cancellation by server, session, and request ID; retire
    queued work and background startup tasks when the add-in stops
  - Add regression coverage for cancellation isolation and Stop/Run races;
    133 automated tests pass on Linux, macOS, and Windows

- v 1.4.0
  - Add `get_viewport` and `set_viewport`: camera snapshots, standard views,
    projection, orbit, pan, zoom, and fit
  - Extend `capture_viewport` with temporary views, transparent or solid
    backgrounds, anti-aliasing control, native dimensions, and cropping
  - Support MCP `2026-07-28` while retaining all three supported 2025
    revisions on the same endpoint; persistent Python calls using the new
    protocol require an explicit `session_id`
  - Fix empty-response framing for HTTP keep-alive clients; validate browser
    origins and scope modern cancellation to individual requests
  - Log the Fusion and Python runtime versions; verify the bundled Autodesk
    utilities against Fusion 2705.1.11
  - Validate with 108 automated tests and 35 live viewport checks on macOS;
    expand Python 3.14 CI to Linux, macOS, and Windows

- v 1.3.0
  - `fetch_online_documentation` returns a `preview` flag, so an agent can see
    that a class is preview API before building on it. Autodesk renames these
    between releases without a deprecation period
  - Design guide: fixed every example, which wrapped its arguments in an
    `operation` field that no tool accepts
  - Design guide: new sections on preview APIs and on sheet metal ordering,
    covering `foldFeatures`, `joinByBendFeatures`, `cornerClosureFeatures` and
    flat patterns

- v 1.2.0
  - `fetch_online_documentation` now understands all three Autodesk help
    layouts. Property pages contribute `property_type`, `access` and
    `property_description`; class pages contribute their `methods`,
    `properties` and `accessed_from` member lists
  - Property syntax lines are recognised (they carry no argument list, and
    Autodesk leaves the emphasis tag unclosed)
  - Fixed every sample on a page inheriting the first sample's URL
  - Fixed descriptions coming back empty, as Autodesk emits `<p class="api">`

- v 1.1.0
  - Negotiate the MCP protocol version instead of always answering
    `2025-03-26`; `2025-11-25` and `2025-06-18` are now supported, which fixes
    clients refusing to connect ([#1](https://github.com/frankhommers/autodesk-fusion-mcp/issues/1))
  - Tolerate the `MCP-Protocol-Version` request header introduced in 2025-06-18
  - `/health` now reports `supported_protocols`
  - Fixed `fetch_online_documentation` silently dropping the `syntax` field
    after Autodesk changed its help markup from `<strong>` to `<b>`
  - Per-command execution duration and ISO 8601 timestamps in the log
  - CI now runs on Python 3.14, matching the interpreter Fusion bundles

- v 1.0.0
  - Initial release
  - 11 dedicated MCP tools with individual schemas
  - Streamable HTTP transport (MCP spec 2025-03-26)
  - Thread-safe main-thread dispatch
  - Viewport selection reader (`get_active_selection`)
  - Python code execution with persistent sessions
  - API documentation introspection
  - Script management (save/load/list/delete)
  - Zero external dependencies
