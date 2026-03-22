# nix-to-deb — Generic function for packaging nix-built applications as .deb
#
# Usage (as a flake):
#   inputs.nix-to-deb.url = "path:../nix-to-deb";  # or github:user/nix-to-deb
#   nixToDeb = nix-to-deb.lib.nixToDeb;
#   myDeb = nixToDeb { inherit pkgs; package = pkgs.myapp; ... };
#
# Usage (direct import):
#   nixToDeb = import ./nix-to-deb;
#   myDeb = nixToDeb { inherit pkgs; package = pkgs.myapp; ... };

{ pkgs
, package                     # The nix package to convert
, pname ? package.pname       # Debian package name
, version ? package.version   # Debian package version

  # --- Target profile (issue #10) ---
  # Auto-detected from pkgs.stdenv.hostPlatform.system.
  # Individual overrides still work for backward compat.
, targetProfile ? {}
, debArch ? null
, interpreter ? null
, systemLibDir ? null

, bundleLibDir ? null         # Where bundled libs install to (default: /usr/lib/${pname})

  # --- Binary discovery (issue #1) ---
, realBinary ? null
, binName ? pname

  # --- What to bundle ---
, excludeLibs ? [ "glibc" ]   # Grep patterns for libs to exclude from bundling
, extraLibs ? []              # Additional .so files to bundle
, extraLibPackages ? []       # Additional packages whose .so files and deps should be bundled
, createCompatSymlinks ? false # Opt-in synthetic .so symlinks
, allowedSystemLibs ? [       # Libs allowed to be unresolved (system-provided)
    "libm.so" "libc.so" "libdl.so" "librt.so" "libpthread.so"
    "libutil.so" "libcrypt.so" "libresolv.so"
    "libnss_dns.so" "libnss_files.so"
    "libgcc_s.so" "libstdc++.so"
    "ld-linux-x86-64.so" "ld-linux-aarch64.so" "linux-vdso.so"
  ]

  # --- GTK resources ---
, gtkSupport ? false
, gdkPixbuf ? pkgs.gdk-pixbuf
, librsvg ? pkgs.librsvg
, dconfLib ? pkgs.dconf.lib
, gsettingsSchemas ? pkgs.gsettings-desktop-schemas
, gtkPackage ? pkgs.gtk4
, typelibPackages ? []

  # --- Wrapper script ---
, extraWrapperEnv ? []

  # --- Data files ---
, shareFiles ? []
, fixDesktopFiles ? true
, fixDbusServices ? true
, fixSystemdServices ? true
, extraShareCopies ? []

  # --- Debian metadata ---
, depends ? null              # null = use profile defaults
, recommends ? []
, section ? "utils"
, homepage ? ""
, maintainer ? "Local Build <noreply@localhost>"
, description ? "${pname} (built from nix)"
, longDescription ? "Built from source using Nix with bundled library dependencies."
, postinst ? null
, postrm ? null
}:

let
  lib = pkgs.lib;

  # --- Import modules ---
  targetProfiles = import ./lib/target-profiles.nix { inherit lib; };
  validate = import ./lib/validate.nix { inherit lib; };
  control = import ./lib/control.nix { inherit lib; };
  wrapper = import ./lib/wrapper.nix { inherit lib; };
  gtkHelpers = import ./lib/gtk.nix { inherit lib pkgs; };
  shellHelpers = import ./lib/shell-helpers.nix { inherit lib pkgs; };

  # --- Resolve target profile (issue #10) ---
  profileOverrides = lib.filterAttrs (_: v: v != null) {
    inherit debArch interpreter systemLibDir;
  };
  resolvedProfile = targetProfiles.resolve {
    system = pkgs.stdenv.hostPlatform.system;
    overrides = targetProfile // profileOverrides;
  };

  resolvedDebArch = resolvedProfile.debArch;
  resolvedInterpreter = resolvedProfile.interpreter;
  resolvedSystemLibDir = resolvedProfile.systemLibDir;
  resolvedDepends = if depends != null then depends else resolvedProfile.defaultDepends;

  bundlePath = if bundleLibDir != null then bundleLibDir else "/usr/lib/${pname}";

  # --- Nix eval-time validations (issue #5) ---
  _v1 = validate.validatePname pname;
  _v2 = validate.validateVersion version;
  _v3 = validate.validateNoNewlines {
    inherit description maintainer section homepage;
  };
  _v4 = builtins.all (c: validate.validateShareDst c.dst) extraShareCopies;

  # --- Pre-render control file (issue #4) ---
  controlFileTemplate = control.renderControlFile {
    inherit pname version section maintainer description longDescription homepage recommends;
    debArch = resolvedDebArch;
    depends = resolvedDepends;
  };

  # --- Pre-render wrapper script ---
  wrapperScript = wrapper.renderWrapperScript {
    inherit binName bundlePath gtkSupport pname extraWrapperEnv;
  };

  # --- Pre-render maintainer scripts ---
  maintainerScripts = control.renderMaintainerScripts {
    inherit postinst postrm;
  };

  # --- Shell helpers ---
  shellFunctions = shellHelpers.mkShellHelpers {
    inherit pname binName package realBinary bundlePath excludeLibs extraLibs
            extraLibPackages createCompatSymlinks allowedSystemLibs;
    systemLibDir = resolvedSystemLibDir;
    interpreter = resolvedInterpreter;
  };

  controlInstallCode = shellHelpers.mkControlInstallCode {
    inherit controlFileTemplate;
  };

  shareCode = shellHelpers.mkShareCode {
    inherit package binName shareFiles extraShareCopies
            fixDesktopFiles fixDbusServices fixSystemdServices;
  };

  verifyCode = shellHelpers.mkVerifyCode {
    inherit pname bundlePath allowedSystemLibs;
  };

  manifestCode = shellHelpers.mkManifestCode {
    inherit pname version;
    debArch = resolvedDebArch;
  };

  # --- GTK code ---
  gtkCode = lib.optionalString gtkSupport (gtkHelpers.mkGtkShellCode {
    inherit pname bundlePath gdkPixbuf librsvg dconfLib
            gsettingsSchemas gtkPackage typelibPackages;
    systemLibDir = resolvedSystemLibDir;
  });

in

# Force evaluation of validations
assert _v1;
assert _v2;
assert _v3;
assert _v4;

pkgs.stdenv.mkDerivation {
  pname = "${pname}-deb";
  inherit version;

  dontUnpack = true;
  dontBuild = true;
  dontFixup = true;

  nativeBuildInputs = [
    pkgs.patchelf
    pkgs.dpkg
    pkgs.removeReferencesTo
    pkgs.jq
    pkgs.file
  ] ++ lib.optionals gtkSupport [
    pkgs.gdk-pixbuf
    pkgs.glib.dev
  ];

  installPhase = ''
    runHook preInstall

    PKG=$out/${pname}_${version}_${resolvedDebArch}
    LIBDIR=$PKG${bundlePath}
    SHAREDIR=$PKG/usr/share

    mkdir -p $PKG/DEBIAN $PKG/usr/bin $LIBDIR

    # =================================================================
    # Load shell function library
    # =================================================================
    ${shellFunctions}

    # =================================================================
    # Control file installer
    # =================================================================
    ${controlInstallCode}

    # =================================================================
    # Share-copying functions
    # =================================================================
    ${shareCode}

    # =================================================================
    # GTK support functions
    # =================================================================
    ${gtkCode}
    ${lib.optionalString (!gtkSupport) ''
      copy_gtk_runtime() { true; }
    ''}

    # =================================================================
    # Verification functions
    # =================================================================
    ${verifyCode}

    # =================================================================
    # Build manifest functions
    # =================================================================
    ${manifestCode}

    # =================================================================
    # Pipeline: resolve → collect → copy → gtk → install → share →
    #           control → verify → manifest → dpkg-deb
    # =================================================================

    resolve_binary
    copy_private_libs
    ${lib.optionalString gtkSupport "copy_gtk_runtime"}
    install_binary

    # Write wrapper script
    cat > $PKG/usr/bin/${binName} <<'WRAPPER_EOF'
${wrapperScript}
WRAPPER_EOF
    chmod +x $PKG/usr/bin/${binName}

    copy_share_tree
    install_control_file

    # Write maintainer scripts
    cat > $PKG/DEBIAN/postinst <<'POSTINST_EOF'
${maintainerScripts.postinst}
POSTINST_EOF
    chmod 755 $PKG/DEBIAN/postinst

    cat > $PKG/DEBIAN/postrm <<'POSTRM_EOF'
${maintainerScripts.postrm}
POSTRM_EOF
    chmod 755 $PKG/DEBIAN/postrm

    verify_package_tree
    write_build_manifest

    # Build .deb
    dpkg-deb --build --root-owner-group $PKG $out/${pname}_${version}_${resolvedDebArch}.deb

    runHook postInstall
  '';
}
