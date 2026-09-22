# Releasing

This document covers everything needed to publish a new version of the n'co studio npm packages and update the Chrome Web Store extension. The actual `npm publish` and store upload are **operator-gated** — only a human with valid credentials should execute those steps.

---

## Semver & versioning policy

### Package versioning

Both npm packages use [Semantic Versioning](https://semver.org/):

| Change | Version bump | Examples |
|--------|-------------|---------|
| Bug fix, documentation | **patch** (0.1.0 → 0.1.1) | Fix MCP error message, README typo |
| New feature, backward-compatible | **minor** (0.1.0 → 0.2.0) | New MCP tool, new CLI flag |
| Breaking change | **major** (0.1.0 → 1.0.0) | Breaking protocol change, removed API |

### Protocol-version policy (WS_PROTOCOL_VERSION)

A breaking change to any of the following = **MAJOR version bump** on both the MCP server package AND a corresponding Chrome extension version bump:

- The WebSocket protocol shape (`WS_PROTOCOL_VERSION` constant in `packages/shared/src/protocol.ts`)
- The `nco-web-editor.componentRoots` configuration key in the target project's `package.json`
- The `NCO_WEB_EDITOR_PORT` environment variable name or semantics
- The `.nco-web-editor/` persistence directory name or schema

Minor additions to the WebSocket protocol that remain backward-compatible (e.g., new optional message fields) = **minor** bump.

### Extension ↔ npm version alignment

The Chrome extension and the two npm packages share a common release gate:

- **Bump all three together** when the WebSocket protocol changes (see above).
- After publishing, record the pairing in `COMPATIBILITY.md`:
  ```
  | 0.4.0 | 0.2.0 | 0.2.0 | Current — component awareness, status protocol |
  ```
- The extension ZIP filename encodes its version (`nco-studio-web-editor-{version}.zip`). Update `packages/chrome-extension/manifest.json` version field to match.

---

## Pre-flight checklist

Run through this before tagging:

- [ ] **`@nco-studio` org and scope available** — both packages under `@nco-studio/` exist in npm, owned by the org
- [ ] **OIDC trusted publisher configured** (see "OIDC setup" below) — or have a short-lived granular token ready for the manual fallback
- [ ] **Version bumped** in both public `package.json` files:
  - `packages/mcp-server/package.json` → `"version"` field
  - `packages/dev-plugin/package.json` → `"version"` field
- [ ] **`CHANGELOG.md` updated** with the new version section and release notes
- [ ] **`COMPATIBILITY.md` updated** if the protocol version changed
- [ ] **All prior verifications green** — smoke test, dry-run, tsc, build all pass locally:
  ```sh
  npm run build --workspaces --if-present
  npm run typecheck --workspaces --if-present
  node scripts/smoke-test.mjs
  node scripts/publish-dry-run.mjs
  ```
- [ ] **No `@frontend-editor` strings** in published packages:
  ```sh
  grep -rn '@frontend-editor' packages/mcp-server/dist/ packages/dev-plugin/dist/
  # → must return zero matches
  ```

---

## Publish order

The two public packages are **independent** — `@nco-studio/shared` is bundled into `mcp-server` via `tsup noExternal` and is not published separately. Either package can be published first.

Recommended order (mcp-server first, as it's the primary consumer touchpoint):
1. `@nco-studio/web-editor-mcp` (packages/mcp-server)
2. `@nco-studio/web-editor-plugin` (packages/dev-plugin)

---

## First release: publish manually

npm only lets you attach a Trusted Publisher to a package that already exists, so the **first** version of each package (v0.2.0) is published by hand. Use the manual steps under "Manual fallback" below, logged in with `npm login` on an account with 2FA that belongs to the `@nco-studio` org. After both packages exist on the registry, set up OIDC (next section) and use the tag-triggered workflow for later releases.

`--provenance` only works when publishing from a CI run on a **public** repository; for the manual first publish, drop the flag.

---

## OIDC Trusted Publishing setup (one-time, operator)

The release workflow (`.github/workflows/release.yml`) uses npm OIDC Trusted Publishing — **no stored long-lived token** is required once configured. Provenance statements require the GitHub repository to be public.

1. Log in to [npmjs.com](https://www.npmjs.com) as the `@nco-studio` org admin
2. Go to each package → **Settings** → **Publish Access** → **New Trusted Publisher**
3. Set:
   - **Repository:** `n-co-studio/web-editor`
   - **Workflow file:** `.github/workflows/release.yml`
   - **Environment:** `release`
4. Repeat for both `@nco-studio/web-editor-mcp` and `@nco-studio/web-editor-plugin`
5. In the GitHub repo settings, create an **Environment** named `release` (Settings → Environments → New environment)

Until this is done the publish job returns `401 Unauthorized`. The workflow is inert; no credentials are leaked.

> **Why OIDC?** npm Classic tokens (long-lived) were deprecated in December 2025. Granular tokens expire in ≤ 90 days, breaking unattended runs. OIDC tokens are ephemeral — issued per-workflow-run, automatically revoked.

---

## Tag + GitHub Release steps

1. Commit all version bumps and changelog updates:
   ```sh
   git add packages/mcp-server/package.json packages/dev-plugin/package.json CHANGELOG.md COMPATIBILITY.md
   git commit -m "chore(release): v0.2.0"
   ```
2. Tag the commit:
   ```sh
   git tag v0.2.0
   git push origin main
   git push origin v0.2.0
   ```
3. The `v*` tag push triggers `.github/workflows/release.yml`. **First release only:** 0.2.0 was already published by hand, so the workflow's publish job fails with "cannot publish over the previously published version". That failure is expected; the tag and GitHub Release are still valid.
4. Once the workflow completes successfully, create a GitHub Release:
   - Go to **Releases** → **Draft a new release**
   - Tag: `v0.2.0`
   - Title: `v0.2.0 — <brief description>`
   - Body: paste from `CHANGELOG.md`
   - Attach: `packages/chrome-extension/dist-zip/nco-studio-web-editor-{version}.zip` (Chrome extension ZIP from `node packages/chrome-extension/scripts/package-extension.mjs`)
5. Publish the guide page: `npm run deploy:site` builds `examples/demo-app` for `/web-editor/` and syncs it into the nco.studio site repo (`NCO_SITE_DIR` overrides the path). It replaces whatever the guide build emits (today `index.html`, `assets/`, `favicon.svg`) under `web-editor/`, never touching `web-editor/privacy/` or anything else in that repo — review, commit and push there to deploy. The guide must be live at https://nco.studio/web-editor/ before the store submission, because the extension opens it on first install.
6. Upload the extension ZIP to the Chrome Web Store (operator-only — see `docs/store-listing.md`).

---

## Manual fallback (if OIDC is not configured)

If the trusted publisher is not yet set up (including the first release), publish manually from a machine logged in with `npm login` (2FA prompts for a one-time code on each publish):

```sh
# 1. Build
npm run build --workspaces --if-present

# 2. Verify
node scripts/smoke-test.mjs
node scripts/publish-dry-run.mjs

# 3. Publish (no --provenance: provenance is only generated from supported CI runs)
cd packages/mcp-server
npm publish --access public
cd ../../packages/dev-plugin
npm publish --access public
```

Alternatively, use a **short-lived granular token** instead of an interactive login (tokens expire in ≤ 90 days; rotate before each release if needed). Set `NPM_TOKEN` in your shell before publishing:
```sh
export NPM_TOKEN=<your-granular-token>
npm config set //registry.npmjs.org/:_authToken "${NPM_TOKEN}"
```

---

## Post-publish smoke checklist (operator runs live after publishing)

After the workflow completes and both packages appear on the npm registry, verify from a **clean directory** (no workspace resolution):

```sh
# 1. MCP server version check
npx --yes @nco-studio/web-editor-mcp@latest --version
# → should print the new semver (e.g. 0.2.0)

# 2. Dev plugin install into demo app
cd examples/demo-app
npm install @nco-studio/web-editor-plugin@latest
# → should install cleanly with no @frontend-editor warnings

# 3. Full smoke test against registry packages
# (reuses scripts/smoke-test.mjs — it packs from source, so also verifies tarball)
cd ../..
node scripts/smoke-test.mjs

# 4. Load the store ZIP in Chrome (developer mode)
# Unpack dist-zip/nco-studio-web-editor-{version}.zip into a temp dir
# chrome://extensions → Load unpacked → select the temp dir
# → extension loads without errors, icon appears in toolbar
```

If any check fails, use the 72-hour npm unpublish window (`npm unpublish @nco-studio/web-editor-mcp@0.2.0`) and the [72h grace period deprecation](https://docs.npmjs.com/deprecating-and-undeprecating-packages-or-package-versions) to pull back, fix, and republish. Version immutability applies after 72h.

---

## Publish risks & guards

| Risk | Guard |
|------|-------|
| Publishing the wrong version | `scripts/publish-dry-run.mjs` tarball assertion before publish |
| `@frontend-editor` strings leaking into dist | `grep` in dry-run + smoke-test checks |
| `src/` files included in tarball | `files` field in `package.json` + dry-run assertion |
| Breaking protocol change without MAJOR bump | Protocol-version policy (see above) |
| Extension version out of sync with packages | `COMPATIBILITY.md` alignment check in pre-flight |
| npm version immutability (72h unpublish window) | Dry-run + smoke-test as mandatory pre-flight gates |
