# nix2deb

Package nix-built applications as self-contained `.deb` files for
Debian/Ubuntu. Bundles all library dependencies from nix while using the
host system's glibc and GPU drivers for hardware compatibility.

## Quick Start

Add as a flake input:

```nix
{
  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    nix2deb.url = "github:barstoolbluz/nix2deb";
  };

  outputs = { nixpkgs, nix2deb, ... }:
    let
      pkgs = import nixpkgs { system = "x86_64-linux"; };
      nixToDeb = nix2deb.lib.nixToDeb;
    in {
      packages.x86_64-linux.default = nixToDeb {
        inherit pkgs;
        package = pkgs.ripgrep;
        binName = "rg";
        shareFiles = [ "man" ];
        description = "Fast regex search tool";
      };
    };
}
```

```bash
nix build .
# Output: result/<pname>_<version>_<arch>.deb
sudo dpkg -i result/ripgrep_*_amd64.deb
```

Try the included example without cloning:

```bash
nix build github:barstoolbluz/nix2deb#example-simple
ls result/  # hello-nix_2.12.2_amd64.deb
```

## How It Works

1. **Bundle libraries** — Walks the ELF dependency closure via
   `patchelf --print-needed` / `--print-rpath`, copies resolved libraries to
   `/usr/lib/<pname>/`, excluding glibc (which must come from the host for GPU
   driver compatibility).

2. **Patch the binary** — `patchelf` sets the system dynamic linker and a
   `RUNPATH` that searches bundled libs first, then system libs:
   `/usr/lib/<pname>:/usr/lib/x86_64-linux-gnu`

3. **Strip nix references** — `remove-references-to` strips residual
   `/nix/store/` paths from binaries and data files.

4. **Wrapper script** — A shell wrapper at `/usr/bin/<name>` sets any required
   environment variables and exec's the patched binary.

5. **Package** — `dpkg-deb` builds the `.deb` with proper control file,
   postinst/postrm scripts, and root ownership.

## GTK Applications

For GTK3/GTK4 apps, enable `gtkSupport = true` to automatically bundle:

- GIO modules (dconf settings backend)
- GDK pixbuf loaders + regenerated `loaders.cache`
- Compiled GSettings schemas
- GObject introspection typelibs
- Wrapper env vars (`GIO_EXTRA_MODULES`, `GDK_PIXBUF_MODULE_FILE`,
  `XDG_DATA_DIRS`, `GI_TYPELIB_PATH`)

```nix
nixToDeb {
  inherit pkgs;
  package = pkgs.my-gtk-app;
  gtkSupport = true;
  gtkPackage = pkgs.gtk4;
  typelibPackages = [ pkgs.gtk4 pkgs.libadwaita pkgs.pango ... ];
  shareFiles = [ "applications" "icons" "man" "locale" ];
};
```

## Choosing a Strategy

| App type | What to set |
|----------|-------------|
| Simple CLI tool (e.g., ripgrep) | Defaults are enough |
| GTK app | `gtkSupport = true` (handles schemas, loaders.cache, schema compilation) |
| Qt / GStreamer / other plugin framework | `discoverModules = true` + `extraLibPackages` for unlinked plugin packages |
| GTK app that also uses GStreamer | Both — `gtkSupport` handles GTK categories, `discoverModules` handles the rest |

## Module Discovery

For applications that `dlopen()` plugins at runtime (GIO modules, Qt plugins,
GStreamer, etc.), enable `discoverModules = true` to automatically scan the ELF
dependency closure for known module patterns and bundle them:

```nix
nixToDeb {
  inherit pkgs;
  package = pkgs.my-qt-app;
  discoverModules = true;
  extraLibPackages = [ pkgs.qt6.qtsvg pkgs.qt6.qtwayland ];
  description = "My Qt application";
};
```

Discovered module categories:

- **GIO modules** (`lib/gio/modules/*.so`) — dconf, etc.
- **GDK pixbuf loaders** (`lib/gdk-pixbuf-2.0/*/loaders/*.so`) — with `loaders.cache` generation
- **Qt plugins** (`lib/qt-*/plugins/*/*.so`) — Qt 5 and Qt 6
- **GStreamer plugins** (`lib/gstreamer-1.0/*.so`)
- **GObject typelibs** (`lib/girepository-1.0/*.typelib`)
- **GSettings schemas** (`share/gsettings-schemas/*/glib-2.0/schemas/*.xml`) — with compilation

The wrapper script sets the corresponding env vars (`QT_PLUGIN_PATH`,
`GST_PLUGIN_PATH`, etc.) conditionally at runtime — only when the directory
actually exists in the installed `.deb`.

**Scope**: Only packages already in the ELF dependency closure are scanned. Plugin
packages that aren't linked (e.g., `qt6.qtsvg`) must be added via `extraLibPackages`
to be discovered. When both `discoverModules` and `gtkSupport` are enabled,
`gtkSupport` takes precedence for GIO/pixbuf/schema/typelib categories.

Use `discoverModuleCategories` to whitelist specific categories:

```nix
discoverModuleCategories = [ "qt6" "gstreamer" ];  # only discover Qt 6 and GStreamer
```

## Full API Reference

### Required

| Parameter | Description |
|-----------|-------------|
| `pkgs` | Nixpkgs package set |
| `package` | The nix package to convert |

### Binary

| Parameter | Default | Description |
|-----------|---------|-------------|
| `pname` | `package.pname` | Debian package name |
| `version` | `package.version` | Debian package version |
| `binName` | `pname` | Binary name in `bin/` |
| `realBinary` | auto-detect | Path to the unwrapped binary (tries `.${binName}-wrapped`) |

### Platform

| Parameter | Default | Description |
|-----------|---------|-------------|
| `debArch` | `"amd64"` | Debian architecture string |
| `interpreter` | `"/lib64/ld-linux-x86-64.so.2"` | System dynamic linker path |
| `systemLibDir` | `"/usr/lib/x86_64-linux-gnu"` | System library directory |
| `bundleLibDir` | `"/usr/lib/${pname}"` | Where bundled libs install to |
| `targetProfile` | `{}` | Override resolved platform profile (debArch, interpreter, systemLibDir) |

### Library Bundling

| Parameter | Default | Description |
|-----------|---------|-------------|
| `excludeLibs` | `[ "glibc" ]` | Grep patterns for libs to exclude |
| `extraLibs` | `[]` | Additional `.so` files to bundle |
| `extraLibPackages` | `[]` | Packages whose `.so` files and deps to bundle |
| `createCompatSymlinks` | `false` | Create `libfoo.so` → `libfoo.so.x.y` compat symlinks |
| `allowedSystemLibs` | glibc, libm, etc. | Library prefixes allowed to be unresolved (system-provided) |
| `discoverModules` | `false` | Auto-discover `dlopen()`'d modules from ELF closure |
| `discoverModuleCategories` | `null` | Whitelist categories (`null` = all, or `[ "gio" "pixbuf" "qt5" "qt6" "gstreamer" "typelibs" "schemas" ]`) |

### GTK Support

| Parameter | Default | Description |
|-----------|---------|-------------|
| `gtkSupport` | `false` | Enable GTK resource bundling |
| `gtkPackage` | `pkgs.gtk4` | GTK package for schemas |
| `gdkPixbuf` | `pkgs.gdk-pixbuf` | Pixbuf loaders source |
| `librsvg` | `pkgs.librsvg` | SVG loader + loaders.cache source |
| `dconfLib` | `pkgs.dconf.lib` | GIO dconf module source |
| `gsettingsSchemas` | `pkgs.gsettings-desktop-schemas` | Desktop schemas |
| `typelibPackages` | `[]` | Packages providing `.typelib` files |

### Wrapper

| Parameter | Default | Description |
|-----------|---------|-------------|
| `extraWrapperEnv` | `[]` | Extra env vars: `[{ name; value; append; }]` |

### Data Files

| Parameter | Default | Description |
|-----------|---------|-------------|
| `shareFiles` | `[]` | Dirs from `share/` to copy (symlinks dereferenced) |
| `extraShareCopies` | `[]` | Extra copies: `[{ src; dst; }]` (dst relative to `/usr/share/`) |
| `fixDesktopFiles` | `true` | Rewrite nix paths in `.desktop` files |
| `fixDbusServices` | `true` | Rewrite nix paths in D-Bus services |
| `fixSystemdServices` | `true` | Rewrite nix paths in systemd services |

### Debian Metadata

| Parameter | Default | Description |
|-----------|---------|-------------|
| `depends` | `[ "libc6 (>= 2.38)" ]` | Package dependencies |
| `recommends` | `[]` | Recommended packages |
| `section` | `"utils"` | Debian section |
| `homepage` | `""` | Homepage URL |
| `maintainer` | `"Local Build <noreply@localhost>"` | Maintainer field |
| `description` | auto | Short description |
| `longDescription` | auto | Long description |
| `postinst` | desktop/icon cache update | Custom postinst script |
| `postrm` | desktop/icon cache cleanup | Custom postrm script |

## Why Bundle Instead of Using System Libraries?

Nix-built binaries are compiled against specific library versions from nixpkgs
(e.g., GTK 4.20.3). The target distro may ship older versions (Debian trixie
has GTK 4.18.6) with missing symbols. Bundling the nix-built libraries avoids
version mismatches while the `RUNPATH` ordering ensures system glibc and GPU
drivers are used for hardware compatibility.

This is particularly important for NVIDIA GPU systems where the proprietary
driver's `libnvidia-eglcore.so` requires legacy glibc symbols (`__malloc_hook`)
that nix's newer glibc has removed.

## Limitations

- **x86_64 and aarch64 Linux auto-detected** — other architectures require
  manual `targetProfile` or `debArch`/`interpreter`/`systemLibDir` overrides
- **~40MB overhead** — bundling ~250 shared libraries adds size
- **glibc floor** — host must have glibc >= what the nix-built libs require
- **dlopen'd modules from unlinked packages** — `discoverModules` scans packages
  already in the ELF closure, but plugin packages that aren't linked (e.g.,
  `qt6.qtsvg`) must be added via `extraLibPackages`. For Qt5 specifically,
  plugins live in the `-bin` output (e.g., `pkgs.qt5.qtbase.bin`)

## Troubleshooting

**"unresolved DT_NEEDED entries found"** — A bundled library needs another
library that wasn't bundled. If the library should come from the host system
(e.g., GPU drivers), add its prefix to `allowedSystemLibs`. If it should be
bundled, add the providing package to `extraLibPackages`.

**"/nix/store references"** — A staged file still contains a nix store path.
For data files, check that the relevant fixup is enabled (`fixDesktopFiles`,
`fixDbusServices`, `fixSystemdServices`). For binaries or libraries, this
usually indicates a `remove-references-to` gap — file an issue.

**App installs but crashes with missing plugin/module** — The plugin's `.so`
files weren't bundled because the plugin package isn't in the ELF dependency
closure. Add it to `extraLibPackages` and enable `discoverModules = true` so
the plugin directory is scanned and bundled.
