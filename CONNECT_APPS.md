# Connect a model to an app

ModelMatrix can prepare a client configuration for a model without making you type its base URL, Model ID or API key. Automatic setup is currently qualified for **Kilo Code 7.8.12** (VS Code extension with its embedded native runtime) and **OpenCode 1.16.2** (CLI/TUI, legacy v1 configuration). Other versions are not silently upgraded or guessed. For another OpenAI-compatible chat client, use **Other app** to obtain connection details.

## Where the option appears

In the web dashboard at `http://localhost:7700`, open **Models & Servers**. The **Connect to an app** section is visible even before you download a model. Select an existing local or managed-host profile, or use **Connect** on a profile/downloaded-model card. In the menu bar, open **Profiles** or **Hugging Face Downloads** and use that model's Connect action. Both interfaces call the same controller.

Downloading is not required if you already have a working ModelMatrix profile. Conversely, downloading a model alone does not install a coding extension or change another app's settings.

## Automatic Kilo/OpenCode configuration

Select a profile, choose the qualified client, and prepare its connection plan. The plan shows the installed client/version, destination JSON/JSONC file, dedicated provider/model names, base URL and wire Model ID, protected credential storage, changed fields and recovery behavior. **Make default** is optional; it is off initially so your current client model remains selected.

Approve the displayed plan to apply it. ModelMatrix inserts only its own provider/model block, retains unrelated providers, credentials, comments, permissions, MCP settings and defaults, saves a private byte backup, and reads the result back. A plan expires and can be used once. If the file/version/source changes after preview, create another plan instead of applying stale approval.

If the client has an `enabled_providers` allow-list, the plan also shows the addition of its own provider ID so the new model can appear. Existing entries are retained, and cleanup removes only a membership ModelMatrix added. An explicit `disabled_providers` entry for that provider is not overridden; invalid or ambiguous filter structures stop automatic writing.

The clients use a reference to a private key file, not a Hugging Face token or a plaintext key in the JSONC. Each connection has its own route, provider namespace and key, so changing one model does not change another model's connection.

ModelMatrix does not install or upgrade Kilo/OpenCode, restart VS Code, or pretend to control an unqualified OpenCode desktop build. Reload the extension or start a fresh TUI/client session when indicated. Project files or environment-specific configuration can override a global file; such a scope remains something to review, not a guaranteed live-client success.

### Qualified global files

| Client | Default target | Native schema |
|---|---|---|
| Kilo Code 7.8.12 | `~/.config/kilo/kilo.jsonc` | Singular `provider`, `npm`, `options.baseURL`, file-referenced `options.apiKey`, `models.<key>.id` |
| OpenCode 1.16.2 | `~/.config/opencode/opencode.json` | The v1 singular `provider` contract, not the newer v2 `providers`/`package`/`settings` contract |

The loader may already use another supported sibling JSON/JSONC file. Review the actual destination displayed in your plan rather than assuming the default above. An unsafe link, ownership conflict, invalid JSONC or unsupported version stops automatic writing; manual details remain available.

## Other app: the connection card

The card provides an OpenAI-compatible provider type, API base URL, server root, model-list endpoint, chat endpoint, exact Model ID, key requirement and readiness. Use the **base URL** for clients asking for an OpenAI base URL; use **server root** only if the client app adds `/v1` itself. Individual request URLs are not interchangeable with the base URL.

After an approved protected connection is created, a typical base is:

```text
http://127.0.0.1:7701/connections/<connection-id>/v1
```

The actual port comes from the running relay. **7700 is the dashboard/controller port**, not the default model API port. The protected route requires its specific ModelMatrix key and exact Model ID. A wrong/revoked key, wrong model, unavailable host or stopped model returns an error; it never falls back to another running model.

Normal copies and request examples contain no credential. Reveal or copy a key only through the explicit secret action, treat it as a password, and never put it in Git or a support screenshot. This key belongs to ModelMatrix and is unrelated to Hugging Face, OpenAI billing or cloud-provider accounts.

Legacy local `/v1` connection details remain available for existing integrations, with their actual no-key policy, but those legacy routes retain their older fallback behavior. Create a protected connection for strict per-model routing. Managed-host connections use the Mac-local protected relay and the paired agent; they do not publish a Linux model port to the network.

Only clients that accept a compatible OpenAI chat API can use these fields. **Other app** does not claim that every extension or application is an external API client, nor that tools, vision, embeddings or the Responses API are supported by every model/runtime. LM Studio is primarily an engine/model-server application; no automatic external-client configuration is claimed for it.

## Test and status labels

**Configured** means the owned client-file fields were written and read back; it does not prove that a currently running extension has reloaded them. **API tested** means the protected endpoint probe succeeded. **Client verified** is separate and cannot be manufactured by an arbitrary request header. Traffic observations show actual requests using that connection, without claiming a cryptographic proof of which desktop app made them. **Reload required** and model/host readiness are independent indicators.

A test does not download a model, install an engine or silently start a stopped profile. Start your model first with its normal ModelMatrix controls. If the model cannot handle coding/tool requests, configuring a connection cannot add that capability to it. Runtime context and any client output-budget limits are not a promise of a model's accuracy or coding quality.

## Reconfigure, disconnect and undo

Repeated setup of an unchanged connection reuses its identity and owned configuration instead of adding duplicates. A trusted profile rename retains the connection; replacing a profile/model never silently changes the old binding. For a changed source, review the reported conflict and use the safe disconnect/reconnect path when required.

**Disconnect** revokes the route/key first, then removes only configuration still matching ModelMatrix's recorded ownership. You may keep the client file intentionally. **Undo** operates only on the owned transaction and cannot restore a revoked credential or overwrite another writer's later edits. Conflicts remain visible for review. Protected backups can contain old client secrets and must remain private.

For a managed Linux host, update the paired agent to the bundled version before using its new connection proxy. When the app/tunnel/host is unavailable, the connection stops serving rather than selecting a local fallback. The listener remains loopback-only; Docker or a client on another computer needs a deliberately configured secure networking path, not an automatically widened bind address.

## CLI

```bash
modelmatrixctl connect profiles
modelmatrixctl connect targets
modelmatrixctl connect details my-profile
modelmatrixctl connect plan my-profile --target kilo
modelmatrixctl connect configure my-profile --target opencode
modelmatrixctl connect list
modelmatrixctl connect verify <connection-id>
modelmatrixctl connect disconnect <connection-id>
modelmatrixctl connect undo <connection-id>
```

A remote profile uses the exact key returned by `connect profiles`, such as `remote:<host-id>:<profile>`. `configure` displays the plan before asking; `plan` plus `apply <plan-id>` is the equivalent separate workflow. Use `--yes` only when that exact operation is approved. `--make-default` is opt-in. CLI key export requires an explicit `--output` new private file path and never prints the key in ordinary output. See `modelmatrixctl connect help` for all options.
