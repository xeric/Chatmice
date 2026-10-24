<div align="center">
  <img width="192" height="192" alt="Chatmice app icon" src="docs/images/chatmice-app-icon.png" />
</div>
<h2 align="center">Chatmice</h2>

<a href="#"><img alt="GitHub top language" src="https://img.shields.io/github/languages/top/xeric/Chatmice"></a> <a href="#"><img alt="GitHub code size in bytes" src="https://img.shields.io/github/languages/code-size/xeric/Chatmice"></a> <a href="https://github.com/xeric/Chatmice/actions/workflows/swift-xcode.yml"><img alt="GitHub Workflow Status" src="https://img.shields.io/github/actions/workflow/status/xeric/Chatmice/swift-xcode.yml"></a> <a href="https://github.com/xeric/Chatmice/blob/main/LICENSE.md"><img alt="GitHub" src="https://img.shields.io/github/license/xeric/Chatmice"></a>
<a href="https://github.com/xeric/Chatmice/releases/latest"><img alt="GitHub all releases" src="https://img.shields.io/github/downloads/xeric/Chatmice/total"></a>

Chatmice is a simple yet powerful native macOS AI chat client that supports most AI providers: ChatGPT, Claude, xAI (Grok), Google Gemini, Perplexity, Ollama, OpenRouter, and almost any OpenAI-compatible APIs.

## Screenshots

<p align="center">
  <img width="1152" alt="Chatmice conversation interface in dark mode" src="docs/images/chatmice-chat.webp" />
</p>

<p align="center">
  <img width="960" alt="Chatmice provider settings in dark mode" src="docs/images/chatmice-providers.webp" />
</p>

## Table of Contents
- [Screenshots](#screenshots)
- [Downloads](#downloads)
  - [Manual](#manual)
- [Contributions](#contributions)
- [Why Chatmice](#why-chatmice)
- [Workspaces](#workspaces)
- [Run with ChatGPT, Claude, xAI or Google Gemini](#run-with-chatgpt-claude-xai-or-google-gemini)
- [Run with Ollama](#run-with-ollama)
- [System requirements](#system-requirements)
- [Project status](#project-status)
- [Build from source](#build-from-source)
- [iCloud Sync Configuration](#icloud-sync-configuration)
- [License](#license)

## Downloads

Download builds from the [Chatmice releases page](https://github.com/xeric/Chatmice/releases). Until the first signed release is published, build the app from source using the instructions below.


## Contributions
Contributions are welcome. Check the [Chatmice issues](https://github.com/xeric/Chatmice/issues) before opening a new issue or pull request.

Chatmice is derived from [macai](https://github.com/Renset/macai), created by Renat Notfullin and its contributors. Chatmice retains the upstream Apache-2.0 license and attribution while developing an independent product direction.


## Why Chatmice
- **macOS-native and lightweight**
- **User-friendly**: simple setup, minimalist light/dark UI
- **Feature-rich**: vision, image generation, search, reasoning, import/export and more
- **Configurable web search**: connect a search provider, choose Web Search or model-native search per conversation, and optionally enable search by default for every new chat. New chats prefer Web Search when the configured provider is enabled and otherwise use Native Search.
- **iCloud Sync**: keep chats, messages, and settings in sync across devices
- **Workspace-aware**: group chats by project, keep local tools inside a selected folder, and reference files with `@`
- **Private and secure**: no telemetry or usage tracking by Chatmice (Note: Apple may collect anonymized telemetry when iCloud Sync is enabled)
- **Native Markdown rendering**: selectable rich text and code use AppKit TextKit; SwiftMath formulas use their native fitting size. Message layout uses measured heights rather than lazy estimates, keeping the latest turn visible when sending or retrying below long content, from waiting for the first token through streaming growth and completion. Scrolling away pauses bottom-following; reaching the bottom or sending another request resumes it. Completing a response does not move a reader who has scrolled away.
  Assistant content fills the available message column up to 720 points. TextKit measures with a separate layout manager sharing the drawing view's text storage, and caches a bounded set of proposed widths. Width probes do not reflow the displayed text or replace its final drawing width; long paragraphs, code, and numbered lists retain correct wrapping after resizing. The drawing layout is prepared and remeasured when text, highlighted code, or the final width changes, not when scrolling first reveals an offscreen paragraph. Streaming code remains measurable native plain text until completion, including already-closed fences while later tokens arrive, instead of running syntax highlighting per token. Unchanged message parsing and native text formatting are cached per message, with content, font, appearance, and search changes reflected in the rendered output. Scrollbar styling runs on window activation and mounted scroll containers, not on every window redraw.
  Scroll-follow and position state live in a separate container. Following reacts to measured content and viewport size changes rather than changing layout traits at the start of a wheel gesture, avoiding historical-message reconstruction while preserving bottom-follow and search navigation.
  GFM tables support optional outer pipes, escaped pipes, column alignment, and inline emphasis/code/links in cells. Setext headings, reference-style links, task lists, horizontal rules, footnotes, GitHub callouts, subscript/superscript, `$...$` inline math, `$$...$$` display math, HTML `<br>`, and link-title tooltips render natively. Nested blockquotes retain visible depth, nested lists keep wrapped-line indentation, and strikethrough remains visible in long TextKit-backed messages.
- **Conversation switching**: the main column shows a loading indicator while destination messages are prepared, without disabling the workspace sidebar. Selecting another chat supersedes the pending load; outdated results cannot replace the latest selection. The conversation title and content switch together when the destination is ready.
- **Automatic context management**: before every user request, Chatmice checks the previous completed turn's provider-reported usage (or its marked `≈` estimate) against the resolved context limit. At 85%, it pauses the user request and displays **Compacting context** with elapsed time while it creates and saves a checkpoint from older messages. It then rebuilds the request from `checkpoint + retained recent messages + current user message`, recalculates the displayed context estimate, switches to **Waiting for model**, and only then contacts the model. Streaming and non-streaming requests use the same preflight. If required compaction fails, Chatmice fails the user request instead of sending known over-threshold context. Original messages remain stored; only the model projection is compacted. Character estimates use Pi-style `ceil(UTF-16 code units / 4)` and vary by language/model; tool-loop provider usage additionally includes agent instructions, tool definitions, calls, and results. Context limits resolve from provider metadata, the built-in registry, or per-model/per-service overrides in **Settings → Providers**. A completed response only records usage for the next preflight—it no longer triggers compaction afterward.
  Saved checkpoints render as one integrated card with a document icon and trailing disclosure chevron. The entire header row toggles expansion; the rotating-arrows icon and narrow disclosure-only hit target are removed. The compact context indicator uses a 2-point track and 10-point labels; click it to inspect input/output counts, the context limit, and the usage source.
- **Message submission**: both Return and the send button reject empty or whitespace-only text when no attachments are present. Attachment-only messages remain supported.
- **Persistent message actions**: completed messages keep their action bar and timestamp visible at 50% opacity. Hovering over the message or action bar restores full opacity.
- **Tool result cards**: completed and failed text results expand and collapse from their header. The output panel changes immediately while only the disclosure arrow animates, keeping repeated clicks responsive in historical and completed streaming messages.
- **Persona controls**: each assistant uses a configurable colored circular SF Symbol icon. The conversation-title icon opens a prompt preview and assistant switcher; compact sidebar rows show only the icon, chat title, and latest message. Chats without a generated title display as **Untitled** with a blue message-bubble icon. Persona prompts stay out of the visible transcript and are sent only as model context. Persona settings provide broad keyword-searchable main and badge catalogs, custom SF Symbol names, optional composed badges, and full-row expansion of advanced icon controls. Symbol grids retain explicit scrollable heights, while the editor form scrolls independently above pinned save controls on smaller windows.
  In **Settings → AI Assistants**, selecting a row expands its preview and Edit/Delete actions directly beneath that row; **Add New** stays in the list header instead of below the complete list.
- **Window appearance**: **Settings → Appearance → Glass Tint / Background Blur** controls the window background. Glass Tint adds a restrained adaptive color wash without covering the backdrop. Background Blur's ten positions evenly span the previous high-strength 8–10 range, so every step produces a visible change between the strong and maximum native materials. The workspace sidebar extends to the top of the window, retaining native window controls, its system toggle, and bottom actions. The conversation title, model picker, search, and file-panel toggle belong to a separate 52-point header inside the main content column; the file inspector owns its full-height right column. Use **⌘S** to toggle the sidebar and drag its divider to resize it.
  The file inspector uses its native boundary and panel background, matching the workspace sidebar without an additional separator or material overlay.
  Model selection and chat search are 36 points high and use capsule-shaped Liquid Glass backgrounds on macOS 26 and later, with translucent capsule borders on earlier macOS versions. The file-panel toggle uses a circular Liquid Glass button; when the inspector opens, the toggle moves to its top-right header above the workspace title and file content.
  The model picker sizes to its model name and expands leftward while remaining next to chat search.
  Native `NSVisualEffectView` layers sample content behind the window. The Background Blur slider continuously blends the high-strength `popover` and `menu` endpoint materials across ten evenly spaced positions; Glass Tint stays at or below 32% opacity so it cannot flatten the frosted detail. The inspector-header toggle is the only file-panel close control; the file-tree title retains its refresh action.
  The main-content header uses within-window frosted material with a 44-point fade into the conversation below and a 48-point fade-in at its left edge to avoid an abrupt material seam beside the sidebar. This visual overlay does not intercept clicks or scrolling and does not extend into the side panels.


## Workspaces

Use the chevron beside **New Chat** to create a workspace and choose its required local folder. The sidebar groups chats by workspace; click a workspace title or its chevron to expand and collapse its chats, drag the title to reorder workspaces, or use the `+` button to start a chat there. The main conversation header shows the workspace path beneath the conversation title; sidebar chat rows do not show paths. File tools, Bash working directories, and Python execution are restricted to that workspace folder.

When reordering workspaces or draggable settings lists, a rounded dashed **Drop here** placeholder marks the insertion position. The source item fades to 60% opacity while the drag preview keeps its original size and 100% opacity. Drop on the indicated position to reorder; leaving the list or pressing **Esc** removes the hint without changing the order. The source returns to full opacity when the drag ends, including cancellation or release outside the window.

Bash and Python commands run in a macOS sandbox. Workspace data access is limited to the selected folder, and Python network access is denied. A non-zero exit or watchdog timeout is reported to the model as a failed tool call instead of a successful result.

Type `@` in the message box to search for and insert a relative file or directory reference from the current workspace. Keep typing to filter (including Chinese names), use **↑/↓** to change the highlighted candidate, and press **Return** to insert it rather than send the message. Clicking a candidate does the same; the caret stays after the complete reference and its separating space. Inserted references are edited as a unit: arrow keys skip their path and Backspace removes the complete reference. **Esc** dismisses the candidate list; Return then sends normally. **New Chat** and **⌘N** follow the selected chat's workspace; with no chat selected, they use **Temporary Chats** at `/tmp/chatmice`. Each workspace's `+` always creates a chat in that group. Creating a chat expands its workspace, selects the new chat in the sidebar, and displays it on the right, even if that workspace was collapsed.

Drag a file or directory from the workspace file tree onto the message input, or choose **Reference in Message** from its context menu, to insert the same atomic `@` reference. The whole input rectangle, including its toolbar and padding, accepts reference drops and highlights its rounded border in the accent color while targeted. Directory references end in `/`; references are restricted to the current workspace and inserted only into the originating window. Existing file attachment drops remain separate.

Temporary Chats does not display its internal folder path and disables the workspace file-browser button. Switching to a regular workspace makes the file browser available again.

The conversation header uses one continuous material layer above the message content and below the header controls. Its opacity fades down through the header into the content; the message background cannot cover the fading portion, and controls remain crisp and interactive.

The `@` candidate list rescans the workspace each time it opens and watches recursive filesystem changes while visible, so newly created, renamed, and deleted files are reflected without restarting the app. Changing the workspace folder cancels the old listing and loads the new folder. Hidden files, symlinks, and package contents remain excluded from suggestions.

Use the native toolbar's right-sidebar button to show or hide the current workspace's file browser. The full-height macOS inspector has its own toolbar section: chat search stays to the left of its divider, while the inspector button stays at the window's trailing edge in both states. Drag the divider to resize it (220–360 points; initially 260); macOS restores the chosen width. The native AppKit outline loads each directory when expanded, includes hidden files, and updates loaded directories on filesystem changes while preserving expansion and selection. Symlinks and application packages are shown as leaves rather than traversed. Double-click a folder to expand or collapse it; double-click a file or press **Space** for Quick Look, or press **Return** to open it. The context menu also offers **Reveal in Finder** and **Copy Relative Path**. The panel follows workspace changes and its header provides refresh and close buttons. No additional package is required.

Use a workspace's **… → Edit…** menu to change its name or folder. Changing the folder affects subsequent tool requests in all its chats; it does not move files. **Delete…** asks for confirmation and permanently deletes every chat in that workspace while leaving its local folder and files untouched. Temporary Chats cannot be edited or deleted, and active conversations must finish or be stopped before their workspace can be changed.

The global **Enable File Tool** switch controls availability, not selection. New chats inherit **Default Tool List**, and each chat can override it in the input toolbar's **Tools** menu. File Tool must be enabled in both layers. When selected, the agent is instructed to use `read_file`, `write_file`, `edit_file`, `list_directory`, and `sql_query` for supported file operations rather than equivalent shell commands. Code Execution remains available for builds, Git, other command-line programs, and computation.

## Run with ChatGPT, Claude, xAI or Google Gemini
To run Chatmice with ChatGPT or Claude, you need an API token. Treat API tokens like passwords. Most commercial providers offer trial credits for new accounts.
Here is how to get API token for all supported services:
- OpenAI: https://help.openai.com/en/articles/4936850-where-do-i-find-my-secret-api-key
- Claude: https://docs.anthropic.com/en/api/getting-started
- Google Gemini: https://ai.google.dev/gemini-api/docs/api-key
- xAI Grok: https://docs.x.ai/docs#models
- OpenRouter: https://openrouter.ai/docs/api-reference/authentication#using-an-api-key

OpenAI Responses providers accept either an API base URL ending in `/v1` or the full `/v1/responses` endpoint. Chatmice normalizes both ordinary and tool-enabled requests to `/responses` and omits temperature for reasoning models. Imported MCP tool schemas retain their parameter properties, descriptions, enums, references, and constraints; required arguments are not reduced to an empty object.

### Provider custom HTTP headers

In **Settings → Providers**, open a provider and edit **Custom HTTP Headers** using one `Header-Name: value` per line, then click **Done**. Header names are case-insensitive; custom values override built-in defaults, including `Authorization`. Invalid header names, duplicate names, and control characters are rejected. Headers apply to chat requests, agent tool turns, context compaction, model fetching, and capability tests; fetching/testing before saving uses the current editor values. Each provider keeps its own headers by provider ID, with values stored in Apple Keychain rather than database/settings backups.

### HTTP/SSE MCP OAuth

In **Settings → MCP Servers**, add or edit a **Remote (HTTP / SSE)** server and enable **OAuth 2.0**. Configure the grant, Token URL, Client ID, optional scopes and resource URI:

- **Authorization Code + PKCE**: configure Authorization URL and choose a callback protocol. **Chatmice protocol** uses the fixed `chatmice://oauth/callback` address. **Local HTTP** fixes `http://localhost:` and lets you edit only the port and callback path (default `18767/mcp-callback`); existing numeric loopback hosts are preserved. Copy the complete address and register that exact redirect URI with the authorization server. A client secret is optional only if the server permits public clients. Save, then click **Sign In** beside the server to authorize in the browser and reconnect.
- **Client Credentials**: enter the client secret; connection obtains a token without browser authorization.

Loopback callbacks support `localhost`, `127.0.0.1`, and `::1`, with an explicit port from 1024 to 65535 and a callback path. The port in **Redirect URI** is the listening port; there is no separate port setting. Chatmice starts the loopback listener before opening the system browser, checks the callback host/path/port and OAuth state, and sends the same redirect URI plus the PKCE verifier during code exchange. The listener closes after the callback, cancellation, or a three-minute timeout. An occupied callback port produces an error rather than silently choosing another port.

The browser callback page displays the Chatmice icon in a centered layout, supports light/dark appearance, and distinguishes a verified callback from an interrupted sign-in. Callback receipt does not imply token exchange or MCP reconnection has completed; return to Chatmice to check the final status.

The server row shows **Signing in…**, then **Authorized · Connecting…** while initialization and tool discovery finish. A POST-only server advertising `405 Allow: POST` skips the unnecessary `/sse` probe. **Sign Out** appears when a usable access token or refreshable authorization is stored, even if MCP is disconnected. Sign Out disconnects the MCP transport and removes access/refresh tokens from Keychain; server configuration and Client Secret are retained. It does not revoke the provider's browser session or token remotely. Routine sync does not reconnect the signed-out row in the current app session; explicit Sign In/Refresh or toggling the server can reconnect (client-credentials grants reacquire tokens automatically).

Secrets and access/refresh tokens are stored in Keychain, not MCP configuration JSON. Token requests use form-encoded client credentials. Expiring tokens refresh when a refresh token is available; client-credentials tokens can be reacquired. A failed refresh surfaces an error; use **Sign In** to authorize again. OAuth takes precedence over a manually configured `Authorization` header on SSE GET, JSON-RPC POST, and initialization notifications. OAuth and authenticated MCP endpoints require HTTPS, except loopback HTTP. Cross-origin redirects and advertised POST endpoints are rejected to prevent credential leakage. Authorization and token endpoints are configured explicitly; automatic OAuth discovery/client registration is not provided.

Raw JSON accepts an optional `oauth` object with `grant` (`authorizationCode` or `clientCredentials`), `authorizationURL`, `tokenURL`, `clientID`, `scope`, `resource`, `redirectURI`, and `credentialID`. New configurations receive a unique credential ID; legacy JSON missing it derives a stable ID from Client ID, redirect URI, and Token URL. Explicit IDs remain unchanged. For older configurations, open **Edit → Save** once to persist the ID; re-enter the client secret and sign in again if credentials were stored under an earlier random ID. Enter secrets in the secure visual-form field, never in Raw JSON. Existing non-OAuth HTTP/SSE and stdio configurations remain supported. Streamable HTTP POST accepts both direct JSON and SSE JSON-RPC responses, while legacy SSE still supports results on the separate GET stream.


### Model Configuration

In **Settings → Providers**, open a provider and click the sliders button beside a configured model. **Model Configuration** supports a custom context-window token limit (minimum 1,024) and independent **Automatic / Supported / Not Supported** overrides for vision/images, files/PDF, audio input, and Thinking. Manual settings take precedence over detection and defaults and apply only to that model on that provider. **Reset to Automatic** clears all model overrides. Click **Save** in the model editor, then **Done** in the provider editor to persist them. Capability settings change upload availability and reasoning controls/request options; they do not add server-side capabilities or increase the model's real context capacity.
The model connection test verifies vision with a 64×64 red image and enough Responses output budget for reasoning and the final answer. A failed or inconclusive vision probe is shown as **not verified**, not as proof of unsupported vision; it does not disable automatic image capability.
The model picker's name-based vision badge fallback includes GPT-5 and GPT-6 model IDs; explicit per-model overrides still take precedence.

If you are new to LLM and don't want to pay for the tokens, take a look Ollama. It supports dozens of OpenSource LLM models that can run locally on Apple M1/M2/M3/M4 Macs.

## Run with [Ollama](https://ollama.com)
Ollama is the open-source back-end for various LLM models. 
Run Chatmice with Ollama:
1. Install Ollama from the [official website](https://ollama.com)
2. Follow installation guides
3. After installation, select model (llama3.1 or llama3.2 are recommended) and pull model using command in terminal: `ollama pull <model>`
4. Open **Settings → Providers**, choose **Add Provider**, then enter Ollama's OpenAI-compatible endpoint (by default `http://127.0.0.1:11434/v1`):

   <img width="960" alt="Add an Ollama-compatible provider in Chatmice" src="docs/images/chatmice-ollama-provider.webp" />

5. Select model, and default AI Assistant and save
6. Test and enjoy!

## System requirements
macOS 15.0 and later (both Intel and Apple chips are supported)

## Project status
Project is in the active development phase.

### Build from source

#### Option 1: With Apple Developer Account (Full Features)

If you have an Apple Developer account and want to build with iCloud Sync support:

1. Clone the repository: `git clone https://github.com/xeric/Chatmice.git`
2. Open `Chatmice.xcodeproj` in Xcode
3. Select your team in Signing & Capabilities
4. *(Optional)* To enable iCloud Sync in Debug builds, remove `DISABLE_ICLOUD` from Build Settings → Swift Compiler → Active Compilation Conditions
5. Build and run

> **Note:** By default, Debug builds have iCloud Sync disabled via the `DISABLE_ICLOUD` flag to simplify contributor setup. Release builds have iCloud Sync enabled.

#### Option 2: Without Apple Developer Account (No iCloud Sync)

If you don't have an Apple Developer account, you can still build and run the app without iCloud Sync:

**Using Xcode:**
1. Clone the repository: `git clone https://github.com/xeric/Chatmice.git`
2. Open `Chatmice.xcodeproj` in Xcode
3. Select the `Chatmice` target → Build Settings tab
4. Search for `CODE_SIGN_ENTITLEMENTS`
5. Change the value from `Chatmice/Chatmice.entitlements` to `Chatmice/Chatmice-no-icloud.entitlements`
6. In Signing & Capabilities, set "Signing Certificate" to "Sign to Run Locally"
7. Build and run

**Using Command Line:**
```bash
git clone https://github.com/xeric/Chatmice.git
cd Chatmice
xcodebuild -scheme Chatmice \
  -configuration Debug \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGN_ENTITLEMENTS="Chatmice/Chatmice-no-icloud.entitlements" \
  DEVELOPMENT_TEAM="" \
  CODE_SIGNING_ALLOWED=NO \
  build
```

> **Note:** The app built without iCloud entitlements will work normally, but the iCloud Sync feature will not be available. All other features (chat, API services, personas, etc.) will work as expected.

### iCloud Sync Configuration

#### For Contributors (Debug Builds)

iCloud Sync is **disabled by default** in Debug builds via the `DISABLE_ICLOUD` compiler flag. This simplifies the development setup and avoids CloudKit-related signing issues for contributors without an Apple Developer account.

**To enable iCloud Sync in Debug builds:**
1. Select the `Chatmice` target → Build Settings tab
2. Search for `SWIFT_ACTIVE_COMPILATION_CONDITIONS` (or "Active Compilation Conditions")
3. Remove `DISABLE_ICLOUD` from the value (leaving just `DEBUG`)
4. Ensure you have proper entitlements and signing configured (see below)

#### For Custom Builds

If you want iCloud Sync to work in a custom build, you must use your own CloudKit container:

1. Create a CloudKit container in your Apple Developer account
2. Enable the iCloud capability for the Chatmice target in Xcode, and add your container
3. Update the `CloudKitContainerIdentifier` value in `Chatmice/Info.plist` to your container ID
4. Ensure your app's bundle identifier matches the one you registered for the container
5. Remove `DISABLE_ICLOUD` from Active Compilation Conditions if present

If `CloudKitContainerIdentifier` is missing, the app falls back to the default container.

## License
[Apache-2.0](https://github.com/xeric/Chatmice/blob/main/LICENSE.md). Chatmice is derived from [macai](https://github.com/Renset/macai); original copyright and attribution notices are retained.
