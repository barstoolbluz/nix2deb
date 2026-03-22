# Control file and maintainer script rendering
#
# Correctly formats the Description field per Debian policy:
# - First line = synopsis (short description)
# - Continuation lines prefixed with single space
# - Blank lines in long description encoded as " ."
{ lib }:

let
  defaultPostinstScript = ''
    #!/bin/sh
    set -e
    if command -v update-desktop-database >/dev/null 2>&1; then
      update-desktop-database -q /usr/share/applications 2>/dev/null || true
    fi
    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
      gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
    fi
  '';

  defaultPostrmScript = ''
    #!/bin/sh
    set -e
    if [ "$1" = "remove" ] || [ "$1" = "purge" ]; then
      if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database -q /usr/share/applications 2>/dev/null || true
      fi
      if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -q /usr/share/icons/hicolor 2>/dev/null || true
      fi
    fi
  '';

in
{
  # Render the DEBIAN/control file content.
  # Uses @@INSTALLED_SIZE@@ placeholder, substituted at build time.
  renderControlFile =
    {
      pname,
      version,
      debArch,
      section,
      depends,
      recommends ? [ ],
      maintainer,
      description,
      longDescription,
      homepage ? "",
    }:
    let
      dependsStr = builtins.concatStringsSep ", " depends;

      # Format long description: each line prefixed with " ", blank lines become " ."
      formatLongDesc =
        text:
        let
          lines = lib.splitString "\n" text;
          formatLine = line: if line == "" then " ." else " ${line}";
        in
        builtins.concatStringsSep "\n" (map formatLine lines);
    in
    builtins.concatStringsSep "\n" (
      [
        "Package: ${pname}"
        "Version: ${version}"
        "Section: ${section}"
        "Priority: optional"
        "Architecture: ${debArch}"
        "Installed-Size: @@INSTALLED_SIZE@@"
        "Depends: ${dependsStr}"
      ]
      ++ (if recommends == [ ] then [ ] else [ "Recommends: ${builtins.concatStringsSep ", " recommends}" ])
      ++ [
        "Maintainer: ${maintainer}"
        "Description: ${description}"
        (formatLongDesc longDescription)
      ]
      ++ (if homepage == "" then [ ] else [ "Homepage: ${homepage}" ])
    );

  defaultPostinst = defaultPostinstScript;
  defaultPostrm = defaultPostrmScript;

  renderMaintainerScripts =
    { postinst, postrm }:
    {
      postinst = if postinst != null then postinst else defaultPostinstScript;
      postrm = if postrm != null then postrm else defaultPostrmScript;
    };
}
