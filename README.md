# Bee

A native macOS API client: requests, collections, environments, variables, pre-request and post-response scripts, with secrets kept out of every file but an encrypted vault.

Swift 6 · SwiftUI + AppKit · arm64 · macOS 26+ · no third-party dependency.

## Install

Download `Bee-<version>.zip` from the [latest release](https://github.com/digivorefr/bee/releases/latest), open it and move **Bee** to Applications. Bee needs a Mac with Apple silicon and macOS 26 or later.

Bee is not notarized by Apple yet, so macOS refuses to open it the first time: go to **System Settings › Privacy & Security**, scroll down to **Security** and click **Open Anyway**. This is asked once per version downloaded by hand.

From version 1.1.0, Bee updates itself (see [Updates](#updates)).

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
| `CHANGELOG.md` | What changed in each version; its first entry is the version of the build, and Bee shows it under Help › What's New in Bee |
| `Scripts/` | `build-app.sh` (bundle), `release.sh` (download archive and GitHub release), `update-key.swift` (release signing key), `version.sh`, `make-icon.swift` (icon) |

## Where data lives

`~/Library/Application Support/Bee/`: `workspace.json`, `collections/`, `environments/`, `history.json`, `settings.json`, `secrets.vault`. The collection files meant to be shared are in `~/Documents/Bee/`.

## Variables

- `{{name}}` anywhere in a request is replaced by the variable of that name: the active environment first, then the collection, then the globals.
- A path segment written `:name` (`/tickets/:ticketId`) is a path variable. Its value is set under **Path variables** and may use `{{variables}}`; left empty, it takes the variable of the same name. The value is percent-encoded as one segment (`a/b` is sent as `a%2Fb`), where a `{{placeholder}}` typed in the URL is pasted as it is.

## Collection files

- Each collection has a file in `~/Documents/Bee` (Settings › Collections chooses another folder), written as a Postman Collection v2.1 document and kept up to date as the collection changes. There is no export step: the file can be sent, committed with the code it describes, or opened in Postman.
- A file dropped in the folder becomes a collection; a file edited elsewhere is read again within two seconds. Bee puts a file in its own form when it first reads it: identifiers are added, so that the same file always names the same requests, and secret values are taken out.
- What the file holds: the tree, the requests, their scripts, the names of the variables. What it never holds: a secret value (the row is written with an empty value and `"beeSecret": true`) and the value of a variable. Those stay on this Mac: variables in Bee's own store, secrets in the vault.
- Bee writes only what it changed. A part of a request the file already says, and what Bee does not model (saved responses, an authorization of a kind Bee cannot send, the description of a row), is left as it was written.
- A file someone changed since Bee last read it is never written over: it is read first. A file that cannot be read is left alone and said once. A file that is deleted is written again: a collection is deleted in Bee, and its file then goes to the Trash.
- Bee's own copy stays in `~/Library/Application Support/Bee/collections/`; forks are never written to a collection file.

## Forks

- **Request › Fork** copies a request of a collection to try things on it. The fork is listed under its original, with an empty cell; its page has another ground, so the two are never mistaken.
- A fork is kept on this Mac only (`workspace.json`), never in the collection. It is sent from the place of its original: same folders, authorization and scripts.
- The parts a fork has not changed (URL, parameters, authorization, headers, body, scripts, settings) follow the original. The parts it changed stay its own.
- **Merge…** puts the changed parts in the original and removes the fork; where the original changed the same part since, the review asks which one to keep. A fork can also be kept as a new request, or discarded. Its secrets have their own entries in the vault, moved to the original by a merge.
- While secrets are locked, Bee cannot tell what a fork changed: forking and merging wait until they are unlocked. Deleting a request that has forks asks first, since they go with it.

## Secrets

- A secret (a secret variable, an authorization credential, a row marked secret) is never encoded by the models: no workspace file, history entry, export or cURL command can contain its value.
- Values live in `secrets.vault`, sealed with AES-256-GCM. The 256-bit key is one item in the login Keychain (`Bee Vault Key`, this device only).
- In the "Request sent" view and in history, a secret is masked where it was put in (path, parameters, headers, body text), whatever its length or encoding. Console lines, test results and error messages are searched for known secret values instead, which cannot catch a value shorter than 4 characters. A response that echoes a secret back is shown masked until revealed.
- A script that copies a secret into another variable makes that variable secret too; turning a secret back into a plain value clears it unless the person just authenticated.
- Revealing or copying a secret asks for Touch ID or the account password; a copied secret is marked concealed and cleared after a minute.
- Rebuilding the app changes its signature: macOS then asks once to let the new build read `Bee Vault Key`.

## Updates

- Once a day, and on Bee › Check for Updates…, Bee asks GitHub for the latest release of this repository (`api.github.com/repos/digivorefr/bee/releases/latest`). The request carries Bee's version and nothing else. Settings › Updates turns the daily question off.
- A newer release is announced with its notes. Bee installs it by itself only when the release holds `Bee-<version>.zip` and its signature `Bee-<version>.zip.sig`, and that signature is valid for the public key shipped in the application (`Resources/update-key.txt`, Ed25519). The archive is checked before it is unpacked: the update is not quarantined by macOS, so this signature is what stands between a published file and code running on the Mac.
- The new version is then checked again (identifier, version, code signature of every file), put in place of the running copy, and Bee restarts. A copy without the public key, or one that macOS runs from the download folder, offers the release page instead.
- While Bee is signed ad hoc, each new version has a new signature: after an update macOS asks once to let it read `Bee Vault Key`.
- What the signature does not cover: which release is the latest. Someone in control of the repository could hide newer versions, or offer again an older genuine one that is still newer than the installed copy. They cannot make Bee install anything the release key did not sign.

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

## Releasing

Once, before the first signed release, create the key updates are signed with:

```bash
swift Scripts/update-key.swift generate
```

It stores the private key in the login Keychain (`Bee Update Signing Key`, read only after macOS asks) and writes the public key to `Resources/update-key.txt`, to commit. Keep a copy of the private key somewhere safe (Keychain Access shows it as the password of that item): without it, the copies of Bee already installed cannot be given another update by themselves; with it, anyone can sign one. The key is never replaced: on another Mac, `swift Scripts/update-key.swift import <file>` puts the saved copy back, and `generate` refuses to run while `Resources/update-key.txt` exists.

Then, for each version:

1. Add a section at the top of `CHANGELOG.md`: `## 1.1.0 — 2027-01-31`, then `### Added`, `### Changed` or `### Fixed` with one `- ` line per change, written for the people who use Bee. That heading is the version of the build.
2. Commit and push.
3. Package and check the result (`dist/Bee-<version>.zip` holds the application and the license, `dist/Bee-<version>.zip.sig` its signature, for which the Keychain asks; the notes are that section of the changelog followed by how to install):

```bash
Scripts/release.sh
```

4. Publish the tag, the archive and its signature as a GitHub release (refused without the release key, unless `--unsigned` is given):

```bash
Scripts/release.sh --publish
```

## License

[PolyForm Noncommercial 1.0.0](LICENSE.md): use, modify and redistribute the code for any noncommercial purpose. Commercial use is not permitted.
