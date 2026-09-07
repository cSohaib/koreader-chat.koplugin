# KOReader AI Chat

A small KOReader plugin for chatting through the **OpenAI Responses API** and
continuing conversations saved as local Markdown files.

- Start a chat or pick a previous `.md` file from your history folder.
- Every request includes the entire conversation, with its original user and
  assistant roles. No `previous_response_id`, conversation IDs, or remote history.
- Change the endpoint and model to use any server implementing the same
  Responses contract. There are no provider adapters.
- Uses KOReader's existing widgets, networking, JSON codec and filesystem library.
  No additional runtime dependencies or build step.

## Install

1. Download this repository using **Code → Download ZIP** and extract it.
2. Rename the extracted folder to **`koreader-chat.koplugin`**.
3. Copy it into KOReader's `plugins` directory. On a typical Kobo installation:
   `/mnt/onboard/.adds/koreader/plugins/koreader-chat.koplugin/`.
   `main.lua` and `_meta.lua` must be directly inside this folder.
4. Restart KOReader. Open **AI Chat** from the main menu (Tools).

Use a recent KOReader build with `ui/trapper` subprocess support and its bundled
`data/ca-bundle.crt`. This plugin targets KOReader on Kobo/Linux; physical Kobo
testing is still needed for this initial version.

## Configure and chat

In **AI Chat → Settings**, set:

| Setting | Value |
| --- | --- |
| API key | Your API key; may be empty for a server that needs no authentication |
| Model | Exact model ID supported by your endpoint; intentionally no hardcoded default |
| Responses endpoint | Defaults to `https://api.openai.com/v1/responses`; enter the complete URL |
| History folder | Defaults to `chat-history` within KOReader's data directory; custom folders are created automatically |

Choose **New chat**, write a message and tap **Send**. Use **Reply** for the next
turn. **Continue previous chat** lists `.md` files in the configured folder,
newest filename first. Select one to read it and continue. **Current chat**
reopens the in-memory conversation, including a reply awaiting a save retry.

The user message is saved **before** the request starts. A failed or cancelled
request leaves it as a pending turn: reopening that file offers **Retry**.
Declining the Wi-Fi prompt also leaves Retry available. Retries are manual;
cancelling locally cannot guarantee the server stopped processing or billing.

Successful assistant replies are saved immediately. Writes use a temporary file
and rename, so an unsuccessful replacement leaves the previous file intact.
If a reply cannot be saved, **Save again** retries the disk write without another
API call. Keep that chat open until saving succeeds; the unsaved reply exists
only in memory and will be lost on restart or if you replace the current chat.

## Markdown format

Filenames are `YYYYMMDDHHmmss.md`, with `-1`, `-2`, etc. if a name already exists.
There is no database, sidecar metadata, or history index. The file itself is the
conversation:

```markdown
My first question.

===

The assistant's answer.

===

My follow-up question.
```

The first message is the user, then roles alternate. An odd number of messages
means the last user message is awaiting an answer. All `.md` files in this folder
are treated as conversations in this format; keep unrelated Markdown elsewhere.
Changing folders changes the picker location; it does not move existing chats.

The model is instructed to avoid a standalone `===` line. For correctness even
when either participant uses one, the writer escapes it as `\===`. Existing
escaped forms gain one more backslash. Loading reverses that escaping. Only an
**exact unescaped `===` line** is a separator, including inside code fences.
When editing files manually, preserve turn order and use `\===` for a literal
line. Empty messages are rejected. CRLF line endings are accepted.

## API behavior and limits

Requests contain `model`, `instructions`, the complete role-tagged `input`,
`store: false`, and `stream: false`. The client extracts assistant `output_text`
and refusal content from the Responses `output` array. It does not assume that
the first output item is text. Incomplete responses and non-text responses show
an error and leave the pending message available for retry.

History is replayed as text messages, as described in the official
[conversation state documentation](https://developers.openai.com/api/docs/guides/conversation-state).
Only visible chat text is retained: no tools, images, reasoning-item persistence,
streaming, model discovery, book context, summarization, or automatic truncation.
Long conversations can exceed the model's context window; the API error is shown
instead of silently dropping earlier messages. Replaying history still consumes
input tokens. `store: false` disables Responses application-state storage, not
every form of provider logging or retention.

The reader shows scrollable **plain text**, including Markdown syntax. Saved
files remain Markdown for use in other readers and editors.

HTTPS checks the CA chain using KOReader's certificate bundle and checks the
hostname against the certificate's Subject Alternative Names. Redirects are
disabled. Plain HTTP is supported for local compatible servers; it transmits the
key and chat without encryption. Requests run in a cancellable subprocess, with
120-second network timeouts. DNS or trickling traffic can exceed socket timeout
limits; tapping the waiting dialog cancels the subprocess.

Settings, including the API key, are stored locally in
`settings/koreader_chat.lua` within KOReader's data directory. The key field is
masked in the UI, but the settings file and conversations are plaintext. Keep
them out of shared backups and source control.

## Development

The implementation is three modules plus plugin metadata:

| File | Responsibility |
| --- | --- |
| `main.lua` | Settings, chat picker, editor/viewer, request lifecycle |
| `chat_history.lua` | Markdown codec, listing and atomic file replacement |
| `chat_api.lua` | Responses payload, HTTP transport, TLS checks, text extraction |

Run the offline tests from this directory:

```sh
# Debian/Ubuntu test dependencies
sudo apt-get install luajit lua-filesystem
luajit tests/run.lua
```

Tests cover Markdown round trips, disk failure, reopening and continuing a file,
request payloads, response extraction, transport failures, TLS hostname matching,
and UI retry/save recovery. Network, JSON codec and widgets are test doubles;
this is not a live OpenAI or hardware integration test.

Before using on a Kobo, check: configure → send → reply → restart KOReader →
continue the same file; then test Wi-Fi cancellation and an invalid API key.

The existing [assistant.koplugin](https://github.com/omer-faruq/assistant.koplugin)
and KOReader's widget/network sources were consulted for integration patterns.
This is a separate, minimal implementation.
