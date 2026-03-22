# Test fixture package builders for nix-to-deb
#
# Provides minimal test packages to exercise different code paths.
{ pkgs }:

let
  lib = pkgs.lib;

  # A simple ELF binary that links libz, with a .test-simple-wrapped variant
  simpleElf = pkgs.runCommandCC "simple-elf" {
    buildInputs = [ pkgs.zlib ];
  } ''
    mkdir -p $out/bin
    cat > main.c <<'EOF'
    #include <stdio.h>
    #include <zlib.h>
    int main() {
      printf("zlib version: %s\n", zlibVersion());
      return 0;
    }
    EOF
    $CC -o $out/bin/.simple-elf-wrapped main.c -lz
    # Also create unwrapped variant for testing
    cp $out/bin/.simple-elf-wrapped $out/bin/simple-elf
  '';

  # Same as simpleElf but no -wrapped variant
  plainBinary = pkgs.runCommandCC "plain-binary" {
    buildInputs = [ pkgs.zlib ];
  } ''
    mkdir -p $out/bin
    cat > main.c <<'EOF'
    #include <stdio.h>
    #include <zlib.h>
    int main() {
      printf("zlib version: %s\n", zlibVersion());
      return 0;
    }
    EOF
    $CC -o $out/bin/plain-binary main.c -lz
  '';

  # Binary with embedded /nix/store string in data section
  leakyBinary = pkgs.runCommandCC "leaky-binary" {
    buildInputs = [ pkgs.zlib ];
  } ''
    mkdir -p $out/bin
    cat > main.c <<'EOF'
    #include <stdio.h>
    // Embed a fake nix store path in the binary's data section
    const char* leak = "/nix/store/aaaabbbbccccdddd-fake-package/lib/libfoo.so";
    int main() {
      printf("hello %s\n", leak);
      return 0;
    }
    EOF
    $CC -o $out/bin/leaky-binary main.c -lz
  '';

  # A simple package with share files
  withShareFiles = pkgs.runCommand "with-share-files" {} ''
    mkdir -p $out/bin $out/share/applications $out/share/icons/hicolor/48x48/apps
    echo '#!/bin/sh' > $out/bin/with-share-files
    echo 'echo hello' >> $out/bin/with-share-files
    chmod +x $out/bin/with-share-files

    cat > $out/share/applications/test.desktop <<DESKTOP
    [Desktop Entry]
    Name=Test App
    Exec=/nix/store/fake-hash-test/bin/with-share-files
    Type=Application
    DESKTOP

    # Create a minimal icon placeholder
    echo "fake-icon-data" > $out/share/icons/hicolor/48x48/apps/test.png
  '';

in
{
  inherit simpleElf plainBinary leakyBinary withShareFiles;
}
