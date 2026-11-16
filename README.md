# Bee

A native macOS API client: requests, collections, environments, variables, pre-request and post-response scripts, with secrets kept out of every file but an encrypted vault.

Swift 6 · SwiftUI + AppKit · arm64 · macOS 26+ · no third-party dependency.

## Build and run

Only the Command Line Tools are required (no Xcode).

```bash
Scripts/build-app.sh --open
```

The app is written to `dist/Bee.app` (ad-hoc signed). Tests: `swift test`.

## Layout

| Path | Content |
|---|---|
| `Sources/BeeCore` | UI-free core: models, variables, HTTP, scripts (JavaScriptCore), vault, storage, runner |
| `Sources/Bee` | The application: model, design system, features |
| `Tests/BeeCoreTests` | Swift Testing suites for the core |
| `design/language.md` | The design language every screen follows |
| `Scripts/` | `build-app.sh` (bundle), `make-icon.swift` (icon) |

## Where data lives

`~/Library/Application Support/Bee/`: `workspace.json`, `collections/`, `environments/`, `history.json`, `settings.json`, `secrets.vault`.

## Variables

- `{{name}}` anywhere in a request is replaced by the variable of that name: the active environment first, then the collection, then the globals.
- A path segment written `:name` (`/tickets/:ticketId`) is a path variable. Its value is set under **Path variables** and may use `{{variables}}`; left empty, it takes the variable of the same name. The value is percent-encoded as one segment (`a/b` is sent as `a%2Fb`), where a `{{placeholder}}` typed in the URL is pasted as it is.

## Secrets

- A secret (a secret variable, an authorization credential, a row marked secret) is never encoded by the models: no workspace file, history entry, export or cURL command can contain its value.
- Values live in `secrets.vault`, sealed with AES-256-GCM. The 256-bit key is one item in the login Keychain (`Bee Vault Key`, this device only).
- In the "Request sent" view and in history, a secret is masked where it was put in (path, parameters, headers, body text), whatever its length or encoding. Console lines, test results and error messages are searched for known secret values instead, which cannot catch a value shorter than 4 characters. A response that echoes a secret back is shown masked until revealed.
- A script that copies a secret into another variable makes that variable secret too; turning a secret back into a plain value clears it unless the person just authenticated.
- Revealing or copying a secret asks for Touch ID or the account password; a copied secret is marked concealed and cleared after a minute.
- Rebuilding the app changes its signature: macOS then asks once to let the new build read `Bee Vault Key`.

## Scripts

JavaScript, global `bee` (alias `pm` for imported Postman scripts):

```js
// Post-response: keep a token for the next requests, as a secret.
bee.environment.set("accessToken", bee.response.json().token, { secret: true });
bee.test("Status is 200", () => bee.response.to.have.status(200));
```

`bee.environment` · `bee.collectionVariables` · `bee.globals` · `bee.variables` · `bee.request` · `bee.response` · `bee.test` · `bee.expect` · `bee.sendRequest` · `bee.crypto` · `bee.base64` · `bee.uuid()` · `console`.

## Debug harness

Debug builds can be driven without a person (`Sources/Bee/App/DebugHarness.swift`):

```bash
Scripts/build-app.sh --debug
BEE_DATA_DIR=$(mktemp -d) BEE_SCENARIO="select:Send JSON;send;snapshot:/tmp/bee.png;quit" dist/Bee.app/Contents/MacOS/Bee
```

`BEE_DATA_DIR` makes the data throwaway (in-memory vault, no Keychain). Release builds ignore both variables.

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): use, modify and redistribute the code for any noncommercial purpose. Commercial use is not permitted.
