# QA Dist Manager

A [Fibaro HC3](https://www.fibaro.com/en/products/home-center-3/) QuickApp that lets you install, upgrade, and downgrade other QuickApps directly from GitHub — without leaving the HC3 UI.

---

## Features

- Load one or more manifest files from GitHub (or any URL)
- Browse all QuickApps listed in the manifests
- See which versions are already installed on your HC3
- Install a new instance or update an existing one to any release
- Syncs files, UI layout, and interfaces during an update
- Supports per-QA "ignore" lists to preserve user-specific files (e.g. `userconfig`)
- Multiple manifest sources — just add more `manifestXxx` QA variables

---

## Installation

1. Download the latest `.fqa` file from the [qaDist repository](https://github.com/jangabrielsson/qaDist) and import it into your HC3.
2. Import it into your HC3 via **Settings → QuickApps → Add QuickApp → Import**.
3. Open the QuickApp and set the `manifestUrl` variable to point to your manifest (see below).
4. Optionally set `githubToken` if you need more than 60 GitHub API requests per hour.

---

## QuickApp Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `manifestUrl` | Yes | URL to a `dist.json` manifest file. Any variable whose name starts with `manifest` is loaded — add more for additional sources (e.g. `manifestFriend`). |
| `githubToken` | No | Personal access token for GitHub API. Leave empty for anonymous access (60 req/hour). |

### Multiple manifest sources

You can load QAs from several publishers at once. Add extra QA variables named with any prefix starting with `manifest`:

```
manifestUrl     = https://raw.githubusercontent.com/jangabrielsson/qaDist/main/dist.json
manifestAlice   = https://raw.githubusercontent.com/alice/hc3-apps/main/dist.json
manifestBob     = https://raw.githubusercontent.com/bob/myapps/main/dist.json
```

All entries are merged. If the same `uid` appears in multiple manifests, the first one wins.

---

## For QA Authors — Publishing Your Own Manifest

To distribute your QuickApps via QA Dist Manager, host a `dist.json` file in your GitHub repository and share the raw URL.

### Manifest schema

```json
{
  "author": "Your Name",
  "quickApps": [
    {
      "name": "My QuickApp",
      "uid": "UNIQUE_ID_STRING",
      "description": "Short description shown in the UI.",
      "url": "https://api.github.com/repos/yourname/your-repo/",
      "fqa": "dist/MyQuickApp.fqa",
      "versionFile": "main",
      "versionPattern": "local VERSION = \"([^\"]+)\"",
      "ignore": ["userconfig"]
    }
  ]
}
```

### Field reference

| Field | Required | Description |
|-------|----------|-------------|
| `author` | Yes | Your name or organisation. Shown in the QA Dist Manager UI. |
| `minVersion` | No | Minimum QA Dist Manager version required to use this manifest (e.g. `"0.1.2"`). If the installed QADist is older, the manifest is skipped with a warning. Omit or leave blank for no restriction. |
| `quickApps` | Yes | Array of QuickApp entries. |
| `name` | Yes | Display name shown in the selector. |
| `uid` | Yes | A stable unique identifier for this QuickApp. Must never change between releases. Used to match already-installed instances on the HC3. Any unique string works — e.g. `"UPD896846032517896"`. |
| `description` | No | Short description shown below the selector. |
| `url` | Yes | GitHub API base URL for the repository: `https://api.github.com/repos/<owner>/<repo>/` |
| `fqa` | Yes | Relative path to the `.fqa` file inside the repo, e.g. `dist/MyApp.fqa`. The file is fetched from the raw GitHub URL at the selected release tag. |
| `versionFile` | No | Name of the Lua file inside an installed QA that contains the version string. Used to show the current version in the Installed dropdown. |
| `versionPattern` | No | Lua `string.match` pattern used to extract the version from `versionFile`. Must capture the version string in a capture group. Example: `local VERSION = "([^"]+)"` |
| `ignore` | No | Array of file names to exclude during updates. Files listed here are never overwritten from the FQA and never deleted if they already exist on the device. Use this to preserve user-edited files like `userconfig`. |

### Releases and tags

QA Dist Manager fetches the list of available versions by calling the GitHub releases API (`/releases`). If no releases are found, it falls back to tags (`/tags`). Publish a GitHub release (or push a tag) for each version you want to make available.

The `.fqa` file must exist at the tagged commit under the path given in `fqa`.

#### How to create a release on GitHub (recommended)

A **release** is the most visible way to publish a version. It appears on your repo's front page and lets you attach files and release notes.

1. Go to your repository on GitHub.
2. In the right-hand sidebar, click **Releases** (or go to `https://github.com/<owner>/<repo>/releases`).
3. Click **Draft a new release**.
4. In the **Choose a tag** field, type a new version string such as `v1.0.0` and select **Create new tag: v1.0.0 on publish**.
5. Fill in a **Release title** (e.g. `Version 1.0.0`) and optionally add release notes.
6. Make sure your `.fqa` file is already committed and pushed to the branch you're releasing from (usually `main`).
7. Click **Publish release**.

> The tag name becomes the value shown in the Release dropdown inside QA Dist Manager. Use a consistent naming scheme like `v1.0.0`, `v1.1.0`, etc.

#### How to create a tag only (lightweight alternative)

If you prefer not to write release notes, you can push a plain git tag. QA Dist Manager will find it via the tags fallback.

Using the GitHub web UI:
1. Go to your repository → **Code** tab.
2. Click the branch/tag dropdown (top-left, shows `main` by default).
3. Type a new tag name such as `v1.0.0` in the search box.
4. Click **Create tag: v1.0.0 on main** (or whatever branch is current).

Using the command line:
```bash
git tag v1.0.0
git push origin v1.0.0
```

#### Versioning convention

It is recommended to use [Semantic Versioning](https://semver.org/): `vMAJOR.MINOR.PATCH`

| Part | When to increment |
|------|-------------------|
| MAJOR | Breaking changes (e.g. removed user-config keys) |
| MINOR | New features, backwards compatible |
| PATCH | Bug fixes only |

Examples: `v1.0.0`, `v1.2.3`, `v2.0.0`

### Generating a UID

A UID is just a string that uniquely identifies your QuickApp. You can use any method:

```bash
# macOS / Linux
echo "UPD$(date +%s%N | head -c 18)"

# Or just use a descriptive string
"uid": "com.example.MyQuickApp"
```

The only requirement is that it stays constant across all releases of the same QuickApp.

### Minimal example

```json
{
  "author": "Alice",
  "quickApps": [
    {
      "name": "My Sensor",
      "uid": "com.alice.MySensor",
      "description": "Reads temperature from my custom sensor.",
      "url": "https://api.github.com/repos/alice/my-sensor/",
      "fqa": "releases/MySensor.fqa"
    }
  ]
}
```

Host this at `https://raw.githubusercontent.com/alice/my-sensor/main/dist.json` and share that URL with users.

---

## How updates work

When you press **Apply** with an existing installed instance selected:

1. Downloads the `.fqa` for the chosen release from GitHub.
2. Compares the file list with what's currently installed.
   - Creates files that are new in the release.
   - Updates content of all non-ignored files.
   - Deletes files that are no longer in the release (unless listed in `ignore`).
3. Syncs interfaces (adds/removes) based on `initialInterfaces` in the FQA.
4. Updates the UI layout (`uiView`, `uiCallbacks`, `viewLayout`) on the device.
5. HC3 automatically restarts the QuickApp after file changes.

---

## Programmatic API

Other QuickApps can call QA Dist Manager via `fibaro.call` to install or update QuickApps automatically — for example to self-update on a daily timer.

Because `fibaro.call` is fire-and-forget, results are delivered asynchronously. Pass `callbackId` and `callbackMethod` in the args table; QA Dist Manager will call `fibaro.call(callbackId, callbackMethod, result)` when finished.

### Methods

#### `apiListReleases(args)`

Fetch the available releases for a QuickApp.

| Arg | Type | Description |
|-----|------|-------------|
| `uid` | string | **Required.** UID of the QuickApp as listed in the manifest. |
| `refresh` | bool | `true` to force a manifest re-fetch even if the cache is fresh. Default `false`. |
| `callbackId` | number | Device ID of the QuickApp to call back. |
| `callbackMethod` | string | Method name to call on the callback device. |

Result:
```lua
{ ok=true,  uid="...", releases={{tag="v1.2.0", name="..."}, ...} }
{ ok=false, uid="...", msg="error description" }
```

#### `apiInstall(args)`

Download and install a new instance of a QuickApp.

| Arg | Type | Description |
|-----|------|-------------|
| `uid` | string | **Required.** UID of the QuickApp. |
| `tag` | string | Release tag to install. `"latest"` or omit for the newest release. |
| `refresh` | bool | Force manifest re-fetch. Default `false`. |
| `callbackId` | number | Callback device ID. |
| `callbackMethod` | string | Callback method name. |

Result:
```lua
{ ok=true,  uid="...", tag="v1.2.0", deviceId=42, msg="..." }
{ ok=false, uid="...", msg="error description" }
```

#### `apiUpdate(args)`

Update an existing installed instance.

When `force=false` (the default) and the manifest entry has `versionFile`/`versionPattern` set, QA Dist Manager reads the running version and skips the update if it already matches the target tag.

| Arg | Type | Description |
|-----|------|-------------|
| `deviceId` | number | **Required.** Device ID of the installed instance. |
| `uid` | string | **Required.** UID of the QuickApp in the manifest. |
| `tag` | string | Target release tag. `"latest"` or omit for the newest release. |
| `force` | bool | `true` to update even if already on the target version. Default `false`. |
| `refresh` | bool | Force manifest re-fetch. Default `false`. |
| `callbackId` | number | Callback device ID. |
| `callbackMethod` | string | Callback method name. |

Result:
```lua
{ ok=true,  uid="...", deviceId=42, tag="v1.2.0", upToDate=false, msg="..." }
{ ok=true,  uid="...", deviceId=42, tag="v1.2.0", upToDate=true,  msg="already at v1.2.0" }
{ ok=false, uid="...", msg="error description" }
```

### Self-updating QuickApp example

```lua
local QADIST_ID  = 10   -- device ID of your QA Dist Manager instance
local MY_UID     = "com.example.MyQuickApp"

function QuickApp:onInit()
    -- Check for updates every 24 hours
    setInterval(function() self:checkForUpdate() end, 24 * 60 * 60 * 1000)
    self:checkForUpdate()
end

function QuickApp:checkForUpdate()
    fibaro.call(QADIST_ID, "apiUpdate", {
        deviceId     = self.id,
        uid          = MY_UID,
        tag          = "latest",
        force        = false,
        callbackId   = self.id,
        callbackMethod = "onUpdateResult",
    })
end

function QuickApp:onUpdateResult(result)
    if result.upToDate then
        self:debug("Already at " .. result.tag .. " — no update needed.")
    elseif result.ok then
        self:debug("Updated to " .. result.tag .. ". HC3 will restart the QA.")
    else
        self:error("Update failed: " .. tostring(result.msg))
    end
end
```

> **Note:** `apiInstall` and `apiUpdate` set an internal busy flag while running. Concurrent calls from different devices will receive `{ ok=false, msg="busy" }` until the current operation finishes.

---

## License

MIT
