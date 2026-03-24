{
  description = "nix-to-deb — Package nix-built applications as .deb files";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
  };

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      nixpkgsFor = forAllSystems (system: import nixpkgs { inherit system; });
    in
    {
      # The main API
      lib.nixToDeb = import ./.;
      lib.default = self.lib.nixToDeb;

      # Formatter
      formatter = forAllSystems (system: nixpkgsFor.${system}.nixfmt-rfc-style);

      # Example packages
      packages = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          nixToDeb = self.lib.nixToDeb;
        in
        {
          example-simple = nixToDeb {
            inherit pkgs;
            package = pkgs.hello;
            pname = "hello-nix";
            binName = "hello";
            description = "GNU Hello packaged from Nix";
            longDescription = "A simple example of nix-to-deb packaging the GNU Hello program.";
            shareFiles = [
              "man"
              "info"
            ];
          };
        }
      );

      # Test checks
      checks = forAllSystems (
        system:
        let
          pkgs = nixpkgsFor.${system};
          nixToDeb = self.lib.nixToDeb;
          fixtures = import ./tests/fixtures.nix { inherit pkgs; };
        in
        {
          # Test 1: Simple ELF with .wrapped variant
          simple-elf = nixToDeb {
            inherit pkgs;
            package = fixtures.simpleElf;
            pname = "test-simple-elf";
            version = "0.1.0";
            binName = "simple-elf";
            description = "Test simple ELF packaging";
          };

          # Test 2: Plain binary (no .wrapped variant)
          plain-binary = nixToDeb {
            inherit pkgs;
            package = fixtures.plainBinary;
            pname = "test-plain-binary";
            version = "0.1.0";
            binName = "plain-binary";
            description = "Test plain binary packaging";
          };

          # Test 3: No excludeLibs — bundle everything
          no-excludes = nixToDeb {
            inherit pkgs;
            package = fixtures.simpleElf;
            pname = "test-no-excludes";
            version = "0.1.0";
            binName = "simple-elf";
            excludeLibs = [ ];
            description = "Test with empty excludeLibs";
          };

          # Test 4: Extra libs from another package
          extra-libs = nixToDeb {
            inherit pkgs;
            package = fixtures.simpleElf;
            pname = "test-extra-libs";
            version = "0.1.0";
            binName = "simple-elf";
            extraLibPackages = [ pkgs.zlib ];
            description = "Test extra lib packages";
          };

          # Test 4b: Module discovery should bundle dlopen() modules from closure packages
          discover-modules-gio = nixToDeb {
            inherit pkgs;
            package = pkgs.hello;
            pname = "test-discover-modules-gio";
            version = pkgs.hello.version;
            binName = "hello";
            discoverModules = true;
            extraLibPackages = [ pkgs.dconf.lib ];
            description = "Test dlopen module discovery with a GIO module provider";
          };

          # Test 5: Compat symlinks opt-in
          compat-symlinks = nixToDeb {
            inherit pkgs;
            package = fixtures.simpleElf;
            pname = "test-compat-symlinks";
            version = "0.1.0";
            binName = "simple-elf";
            createCompatSymlinks = true;
            description = "Test compat symlink creation";
          };

          # Test 6: Leftover /nix/store refs should fail the build
          leftover-refs-fails =
            let
              badDeb = nixToDeb {
                inherit pkgs;
                package = fixtures.leakyBinary;
                pname = "test-leaky";
                version = "0.1.0";
                binName = "leaky-binary";
                description = "Should fail verification";
              };
              failed = pkgs.testers.testBuildFailure badDeb;
            in
            pkgs.runCommand "test-leftover-refs-fails" { } ''
              exitCode=$(cat ${failed}/testBuildFailure.exit)
              if [ "$exitCode" -eq 0 ]; then
                echo "FAIL: build should have failed but exited 0"
                exit 1
              fi
              if ! grep -q 'nix/store' ${failed}/testBuildFailure.log; then
                echo "FAIL: build failed but not due to /nix/store violation"
                cat ${failed}/testBuildFailure.log
                exit 1
              fi
              echo "PASS: build correctly failed with /nix/store violation"
              mkdir -p $out
              echo "pass" > $out/result
            '';

          # Test 7: Unresolved DT_NEEDED should fail the build
          unresolved-dep-fails =
            let
              badDeb = nixToDeb {
                inherit pkgs;
                package = fixtures.simpleElf;
                pname = "test-unresolved";
                version = "0.1.0";
                binName = "simple-elf";
                excludeLibs = [
                  "glibc"
                  "zlib"
                ];
                description = "Should fail on unresolved dep";
              };
              failed = pkgs.testers.testBuildFailure badDeb;
            in
            pkgs.runCommand "test-unresolved-dep-fails" { } ''
              exitCode=$(cat ${failed}/testBuildFailure.exit)
              if [ "$exitCode" -eq 0 ]; then
                echo "FAIL: build should have failed but exited 0"
                exit 1
              fi
              if ! grep -q 'unresolved DT_NEEDED' ${failed}/testBuildFailure.log; then
                echo "FAIL: build failed but not due to unresolved DT_NEEDED"
                cat ${failed}/testBuildFailure.log
                exit 1
              fi
              echo "PASS: build correctly failed with unresolved DT_NEEDED"
              mkdir -p $out
              echo "pass" > $out/result
            '';

          # Test 8: Real-world package (hello)
          real-world-hello = nixToDeb {
            inherit pkgs;
            package = pkgs.hello;
            pname = "hello-nix";
            binName = "hello";
            version = pkgs.hello.version;
            description = "GNU Hello from nix";
            shareFiles = [
              "man"
              "info"
            ];
          };

          # Test 9: Share file copying and desktop fixup
          share-fixups = nixToDeb {
            inherit pkgs;
            package = fixtures.withShareFiles;
            pname = "test-share-fixups";
            version = "0.1.0";
            binName = "with-share-files";
            shareFiles = [
              "applications"
              "icons"
            ];
            description = "Test share file fixups";
          };

          # TODO: Add GTK packaging test (requires a real GTK application fixture)
        }
      );
    };
}
