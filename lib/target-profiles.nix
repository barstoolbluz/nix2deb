# Target platform profiles for Debian packaging
#
# Each profile defines the architecture-specific paths and metadata needed
# to produce a correct .deb for a given platform.
{ lib }:

let
  profiles = {
    "x86_64-linux" = {
      debArch = "amd64";
      systemLibDir = "/usr/lib/x86_64-linux-gnu";
      interpreter = "/lib64/ld-linux-x86-64.so.2";
      multiarchTriplet = "x86_64-linux-gnu";
      defaultDepends = [ "libc6 (>= 2.38)" ];
    };
    "aarch64-linux" = {
      debArch = "arm64";
      systemLibDir = "/usr/lib/aarch64-linux-gnu";
      interpreter = "/lib/ld-linux-aarch64.so.1";
      multiarchTriplet = "aarch64-linux-gnu";
      defaultDepends = [ "libc6 (>= 2.38)" ];
    };
  };

  # Resolve a target profile from system string, with caller overrides.
  # Backward compatible: callers passing debArch/interpreter/systemLibDir
  # still work — their values override the profile defaults.
  resolve =
    { system, overrides ? { } }:
    let
      base = profiles.${system} or (throw "nix-to-deb: unsupported system '${system}'. Supported: ${builtins.concatStringsSep ", " (builtins.attrNames profiles)}");
    in
    base // (lib.filterAttrs (_: v: v != null) overrides);

in
{
  inherit profiles resolve;
}
