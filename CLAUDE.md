# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

nix-to-deb is a Nix library that packages nix-built applications as self-contained `.deb` files. It bundles all shared library dependencies from nixpkgs while preserving host glibc and GPU drivers for hardware compatibility. The main API is a single function (`nixToDeb`) exposed via `lib.nixToDeb` in the flake.

## Build & Test Commands

```bash
# Build the example package
nix build .#example-simple

# Run all checks (10 test cases: 8 positive, 2 negative)
nix flake check

# Run a single check
nix build .#checks.x86_64-linux.simple-elf

# Format code
nix fmt

# Quick evaluation check (catches Nix syntax/eval errors without building)
nix eval .#checks.x86_64-linux --apply builtins.attrNames
```

The formatter is `nixfmt-rfc-style`. Supported systems: `x86_64-linux`, `aarch64-linux`.

## Architecture

### Code generation at eval time, execution at build time

Each `lib/*.nix` module is a **code generator**: it produces bash shell code snippets as Nix strings at evaluation time. `default.nix` orchestrates these — collecting all generated shell functions and composing them into a single `installPhase` script inside `mkDerivation`. No module runs shell code directly during Nix evaluation.

### Module responsibilities

| Module | Generates |
|--------|-----------|
| `shell-helpers.nix` | Core build functions: `resolve_binary`, `collect_elf_closure`, `copy_private_libs`, `install_binary`, `compute_glibc_floor`, `verify_package_tree`, `write_build_manifest` |
| `control.nix` | Debian `control` file content and `postinst`/`postrm` maintainer scripts |
| `wrapper.nix` | `/usr/bin/<binName>` wrapper script that sets env vars and execs the real binary |
| `gtk.nix` | `copy_gtk_runtime` function (pixbuf loaders, GIO modules, schemas, typelibs) |
| `validate.nix` | Eval-time validators for pname, version, control fields, share paths |
| `target-profiles.nix` | Platform profile resolution (arch, interpreter, system lib dir) |

### Build pipeline (installPhase order)

1. `resolve_binary()` — find the real binary (checks `.${binName}-wrapped` then `${binName}`)
2. `copy_private_libs()` — walk ELF closure via `patchelf --print-needed` / `--print-rpath`, copy bundled libs
3. `copy_gtk_runtime()` — (if `gtkSupport`) bundle GTK assets
4. `install_binary()` — patch interpreter/RPATH, scrub nix refs with `remove-references-to`
5. Install wrapper script
6. `copy_share_tree()` — copy share files, rewrite nix paths in .desktop/dbus/systemd files
7. `compute_glibc_floor()` — scan staged ELFs for `GLIBC_*` version tags, compute minimum libc6 dependency
8. `install_control_file()` — write DEBIAN/control, substitute `@@INSTALLED_SIZE@@` and `@@NIX_TO_DEB_DEPENDS@@`
9. Write `postinst`/`postrm` maintainer scripts
10. `write_build_manifest()` — JSON metadata at `/usr/share/doc/<pname>/build-manifest.json`
11. `verify_package_tree()` — fail on any leftover `/nix/store` refs or unresolved `DT_NEEDED`
12. `dpkg-deb --build`

### Key design decisions

- **patchelf-based closure** — uses `patchelf --print-needed` and `--print-rpath` for deterministic library discovery (not `ldd` scraping)
- **Eval-time validation** — pname/version/metadata validated before build starts (fast failure)
- **Wrapper indirection** — real binary at `/usr/bin/.<binName>-bin`, wrapper at `/usr/bin/<binName>`
- **Verification is mandatory** — `/nix/store` leaks and unresolved `DT_NEEDED` entries are hard build failures, not warnings
- **First-wins collision** — when the same library basename appears from multiple sources, the first copy wins
- **Dynamic glibc floor** — `Depends: libc6 (>= ...)` is computed at build time from `GLIBC_*` version tags via `readelf`, not hardcoded
- **GTK is opt-in** — simple packages stay simple; GTK apps enable `gtkSupport = true`

## Test suite

Tests live in `flake.nix` `checks` and `tests/fixtures.nix`. Fixture packages are minimal C programs built with `pkgs.runCommandCC`.

- **Positive tests**: `simple-elf`, `plain-binary`, `no-excludes`, `extra-libs`, `compat-symlinks`, `real-world-hello`, `share-fixups`, `discover-modules-gio`
- **Negative tests**: `leftover-refs-fails` and `unresolved-dep-fails` use `pkgs.testers.testBuildFailure` to assert that bad inputs produce the expected build failure

## Key conventions

- Shell code uses `''...''` (double-single-quote) Nix multiline strings. Inside these, `${...}` is Nix interpolation; use `''${varname}` for a literal bash `${varname}`. Plain `$VAR` (no braces) passes through unchanged. In the rare `"..."` Nix strings (e.g., `wrapper.nix` `mkEnvLine`), use `\${varname}` instead.
- Issue numbers referenced in comments (e.g., `# issue #1`) refer to design decisions tracked in commit history.
- `shell-helpers.nix` uses global bash variables (`RESOLVED_BINARY`, `_ELF_CLOSURE_VISITED`, `_ELF_CLOSURE_LIBS`) for state across functions.
- `control.nix` uses `@@INSTALLED_SIZE@@` and `@@NIX_TO_DEB_DEPENDS@@` placeholders in rendered control text, substituted at build time with `du -sk` and `compute_glibc_floor` output respectively.
