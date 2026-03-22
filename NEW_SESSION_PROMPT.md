# Prompt for coding agent: harden and refactor `nixToDeb`

You are working on a small Nix library that converts a Nix-built app into a Debian `.deb`. The current implementation lives mainly in `default.nix`, with a very small `flake.nix` that exports the library.

Your job is to shore up the current implementation without breaking the public API more than necessary. Keep the existing entry point and current argument names where practical, but improve correctness, validation, and testability.

## Primary objective

Refactor the current implementation around this pipeline:

1. Resolve the real binary once.
2. Collect its ELF runtime closure deterministically.
3. Stage the package tree.
4. Verify the staged tree.
5. Render Debian metadata and build the `.deb`.

Keep the result focused on the current scope: packaging a native ELF application into a `.deb`, with optional GTK/share handling and wrapper env vars.

## Current shortcomings to fix

### 1) Binary resolution bug

Today the code detects a wrapped binary early, uses that path for dependency collection, then later falls back to `${package}/bin/${binName}` when copying the executable. That can produce a package that builds but is missing shared library deps at runtime.

#### Required change

Create one helper that resolves the actual binary path once, validates that it exists, and returns that path. Use this resolved path everywhere:

* dependency collection
* binary copy/install
* wrapper creation or patching
* any runtime inspection

#### Acceptance criteria

* If `.${binName}-wrapped` exists, that path is used consistently.
* If it does not exist, `${package}/bin/${binName}` is used consistently.
* The build fails early with a clear error if neither exists.

---

### 2) Empty `excludeLibs` bug

The current implementation builds a grep exclusion regex from `excludeLibs`. When the list is empty, it becomes `grep -v ''`, which drops every line and prevents all library bundling.

#### Required change

Make the filtering conditional:

* if `excludeLibs` is empty, do not run the exclusion grep at all
* if non-empty, apply filtering safely

#### Acceptance criteria

* `excludeLibs = []` still bundles runtime libraries normally
* non-empty `excludeLibs` still removes matching libs
* add tests for both cases

---

### 3) Weak ELF dependency discovery

The current implementation scrapes `ldd` output with `awk '{print $3}'`. That is not a strong base for a reusable tool.

#### Required change

Replace the text-scrape approach with a deterministic ELF dependency walker.

Preferred direction:

* read `DT_NEEDED` entries via `patchelf --print-needed` or `readelf -d`
* resolve needed libraries against the binary's runtime search paths
* recurse until closure is complete
* fail if a needed library cannot be resolved and is not explicitly allowed as a system dependency

Also account for:

* symlink chains
* duplicate basenames from different source paths
* non-ELF files encountered during the walk

#### Acceptance criteria

* dependency collection no longer depends on parsing `ldd` text output
* unresolved libraries fail the build with a useful message
* closure walking is stable across common ELF layouts

---

### 4) Control file long-description formatting

The current control-file rendering writes `longDescription` inline, which breaks Debian continuation rules for multiline descriptions.

#### Required change

Move control-file rendering into a dedicated helper that formats Debian control fields correctly.

For `Description`:

* first line is the short description
* each continuation line begins with one leading space
* blank lines in the long description are encoded as ` .`

Also sanitize field values that should not contain raw newlines.

#### Acceptance criteria

* multiline long descriptions render correctly
* blank lines are encoded correctly
* malformed metadata fails fast rather than producing a bad package

---

### 5) Metadata validation

The current implementation inserts `pname`, `version`, and related metadata directly into file paths and Debian control fields.

#### Required change

Add validation or normalization for at least:

* Debian package name syntax
* Debian version syntax
* metadata fields that must not contain raw newlines
* `extraShareCopies[*].dst` being relative and safe

Fail early on invalid input.

#### Acceptance criteria

* invalid package names fail with a clear error
* invalid versions fail with a clear error
* unsafe metadata does not reach the final control file

---

### 6) Final staged-tree verification

The current code rewrites some text files and calls `remove-references-to`, but it does not run a final verification pass over the staged payload.

#### Required change

Add a final verification step before building the `.deb`.

The verifier should:

* scan staged files for `/nix/store` references
* allowlist only known acceptable cases, if any
* fail on leftover store paths
* inspect staged ELF files for unresolved runtime dependencies
* report what failed in a readable way

#### Acceptance criteria

* packages with leftover `/nix/store` refs fail the build
* packages with unresolved runtime deps fail the build
* passing builds emit a small verification summary

---

### 7) Basename collisions in bundled libraries

The current implementation flattens copied libraries into one private lib dir and keys by basename. Two different source libraries with the same basename can collide silently.

#### Required change

Pick one of these approaches:

* fail on non-identical basename collisions with a clear error, or
* preserve enough directory structure to avoid collisions

If you keep the flat layout, collision detection must be explicit.

#### Acceptance criteria

* no silent overwrite or silent skip on conflicting basenames
* collisions are surfaced clearly to the caller

---

### 8) Synthetic `.so` links

The current implementation invents generic `.so` symlinks from versioned runtime libraries. That is risky because upstream may never have shipped that link.

#### Required change

Do not invent new generic `.so` links by default.

Instead:

* preserve symlink chains that already exist in the source library tree
* only create new compatibility links if explicitly requested by an opt-in argument

#### Acceptance criteria

* versioned runtime libs are copied with their existing symlink relationships intact
* generic `.so` links are not fabricated unless the caller opts in

---

### 9) GTK handling

The current GTK support is too tied to one nixpkgs layout and rewrites cached/generated files rather than generating them from the staged tree.

#### Required change

Move GTK support into a dedicated helper/module.

For GTK-related assets:

* stage loaders/plugins/assets into the package tree
* generate `loaders.cache` from the staged loaders with `gdk-pixbuf-query-loaders`
* compile schemas from the staged tree rather than swapping placeholders into copied output
* fail if unresolved store paths remain in GTK-generated output

Do not hardcode layout fragments like `gdk-pixbuf-2.0/2.10.0` unless there is no better option. Prefer discovery from the inputs or nixpkgs data.

#### Acceptance criteria

* GTK packaging uses generated staged artifacts where possible
* GTK support is isolated from non-GTK packaging logic
* no placeholder-path tricks remain unless there is a documented reason

---

### 10) Architecture and target defaults

The current defaults are centered on amd64/x86_64. Those are exposed as arguments, but the implementation should have a cleaner target abstraction.

#### Required change

Introduce a target profile abstraction, even if v1 only ships a small set of profiles.

A profile should capture:

* Debian arch string
* multiarch/system lib dir
* ELF interpreter path
* baseline system dependency policy
* distro/suite label if needed later

Derive sane defaults from `pkgs.stdenv.hostPlatform`, with override support.

#### Acceptance criteria

* current amd64 behavior keeps working
* arm64 support can be added cleanly
* target-specific values are not scattered through the install script

## Structural refactor

The current implementation places most logic in one long shell-heavy `installPhase`. Break it into helpers so the main function becomes an orchestrator.

Suggested helper structure:

* `resolveBinary`
* `collectElfClosure`
* `copyPrivateLibs`
* `copyGtkRuntime`
* `copyShareTree`
* `renderControlFile`
* `renderMaintainerScripts`
* `verifyPackageTree`
* `writePlanManifest`

These can be Nix helpers that emit shell fragments, pure Nix helpers for validation/rendering, or a mix of both.

## Add a build manifest for debugging

Emit a machine-readable manifest into the build output, such as JSON, capturing:

* resolved binary path
* bundled libraries
* skipped libraries and why
* copied share paths
* rewritten files
* generated GTK assets
* remaining declared system dependencies
* final control fields
* verification results

This is for debugability and post-build inspection.

## Public API guidance

Keep the current API shape where practical, including the existing escape hatches such as:

* `extraLibs`
* `extraLibPackages`
* `shareFiles`
* `extraShareCopies`
* wrapper environment vars

It is fine to add new optional arguments for:

* collision policy
* target profile
* explicit allowed system libraries
* opt-in compatibility symlink creation
* multiple binaries later, if you can add it without destabilizing the current interface

Do not turn this into a broad general package conversion framework in this pass. Keep it centered on native ELF app packaging.

## Tests to add in `flake.nix`

Expand the flake with checks that exercise real fixture packages. Add at least:

1. a simple ELF binary package
2. a package where only the plain binary exists
3. a package with `excludeLibs = []`
4. a package with GTK assets
5. a package with extra bundled libs
6. a package expected to fail due to leftover `/nix/store` refs or unresolved runtime deps
7. a package that triggers a library basename collision

Also add:

* `formatter.${system}`
* example packages under `packages.${system}`
* optional convenience alias like `lib.default = self.lib.nixToDeb`

## Output expectations

Please deliver:

1. the refactored Nix code
2. any added helper files/modules
3. updated `flake.nix` checks/examples
4. a short design note explaining the new internal flow
5. a short migration note listing any new optional arguments or behavior changes

## Constraints

* Keep the implementation approachable for a small library.
* Prefer failing early over producing a `.deb` that builds but breaks at runtime.
* Keep the current high-level use case intact: package a Nix-built native app as a Debian package with a private runtime tree.
* Avoid large API churn unless there is a strong correctness reason.

## Nice-to-have, if time permits

* support for multiple binaries via a new optional `binaries = [ ... ]` interface while preserving the current single-binary flow
* extensible `control = { ... };` metadata rendering for fields like `Recommends`, `Provides`, `Conflicts`, and `Replaces`
* clearer handling of wrapper-script-heavy packages

## Definition of done

The work is done when:

* the current correctness bugs are fixed
* dependency closure collection is deterministic and validated
* staged-tree verification catches leftover store refs and unresolved runtime deps
* Debian metadata rendering handles multiline descriptions correctly
* tests in the flake cover the main success and failure paths
* the code is split into helpers that make future maintenance easier
