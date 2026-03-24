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
    nix2deb.url = "github:youruser/nix2deb";
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
sudo dpkg -i result/ripgrep_*_amd64.deb
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

### Library Bundling

| Parameter | Default | Description |
|-----------|---------|-------------|
| `excludeLibs` | `[ "glibc" ]` | Grep patterns for libs to exclude |
| `extraLibs` | `[]` | Additional `.so` files to bundle |
| `extraLibPackages` | `[]` | Packages whose `.so` files and deps to bundle |

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

- **x86_64 only by default** — override `debArch`, `interpreter`, and
  `systemLibDir` for other architectures
- **~40MB overhead** — bundling ~250 shared libraries adds size
- **glibc floor** — host must have glibc >= what the nix-built libs require
- **dlopen'd modules need manual discovery** — static ELF dependency walking
  doesn't see GIO modules, pixbuf loaders, Qt plugins, etc. Use `gtkSupport`
  for GTK apps or `extraLibPackages` for others
