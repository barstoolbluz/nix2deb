# Nix eval-time validation for Debian package metadata
#
# All checks run during evaluation — instant feedback, no build wait.
# Follows Debian Policy Manual where applicable.
{ lib }:

{
  # Debian policy 5.6.1: lowercase alphanumerics, '+', '-', '.'
  # Must start with alphanumeric, minimum 2 characters.
  validatePname =
    pname:
    if builtins.match "^[a-z0-9][a-z0-9.+\\-]+$" pname == null then
      throw "nix-to-deb: invalid pname '${pname}'. Must match Debian policy: lowercase alphanumerics, '+', '-', '.', starting with [a-z0-9], minimum 2 characters."
    else
      true;

  # Debian version: must start with digit.
  # Allowed chars: alphanumerics, '.', '+', '~', '-'
  validateVersion =
    version:
    if builtins.match "^[0-9][A-Za-z0-9.+~\\-]*$" version == null then
      throw "nix-to-deb: invalid version '${version}'. Must start with a digit and contain only [A-Za-z0-9.+~-]."
    else
      true;

  # Newlines in control fields break dpkg-deb
  validateNoNewlines =
    fields:
    let
      check =
        name: value:
        if builtins.length (lib.splitString "\n" value) > 1 then
          throw "nix-to-deb: field '${name}' must not contain newlines."
        else
          true;
    in
    builtins.all (x: x) (builtins.attrValues (builtins.mapAttrs check fields));

  # Validate share destination paths: relative, no '..', non-empty
  validateShareDst =
    dst:
    if dst == "" then
      throw "nix-to-deb: extraShareCopies dst must not be empty"
    else if builtins.match "^/" dst != null then
      throw "nix-to-deb: extraShareCopies dst '${dst}' must be relative (no leading '/')"
    else if builtins.match "(|.*/)\\.\\.(/.*|)" dst != null then
      throw "nix-to-deb: extraShareCopies dst '${dst}' must not contain '..'"
    else
      true;

  # binName must be a valid filename: starts with alphanumeric, rest [a-zA-Z0-9._+-]
  validateBinName =
    binName:
    if builtins.match "[a-zA-Z0-9][a-zA-Z0-9._+\\-]*" binName == null then
      throw "nix-to-deb: invalid binName '${binName}'. Must start with alphanumeric and contain only [a-zA-Z0-9._+-]."
    else
      true;
}
