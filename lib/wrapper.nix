# Wrapper script generation
#
# Generates the /usr/bin/<binName> shell wrapper that sets up the
# environment before exec-ing the real binary.
{ lib }:

{
  renderWrapperScript =
    {
      binName,
      bundlePath,
      gtkSupport ? false,
      pname ? binName,
      extraWrapperEnv ? [ ],
    }:
    let
      gtkEnv = lib.optionals gtkSupport [
        {
          name = "GIO_EXTRA_MODULES";
          value = "${bundlePath}/gio/modules";
          append = true;
        }
        {
          name = "GDK_PIXBUF_MODULE_FILE";
          value = "${bundlePath}/gdk-pixbuf-2.0/loaders.cache";
          append = false;
        }
        {
          name = "XDG_DATA_DIRS";
          value = "/usr/share/${pname}-schemas:/usr/share";
          append = true;
        }
        {
          name = "GI_TYPELIB_PATH";
          value = "${bundlePath}/girepository-1.0";
          append = true;
        }
      ];
      allEnv = gtkEnv ++ extraWrapperEnv;
      mkEnvLine =
        e:
        if e.append or false then
          "export ${e.name}=\"${e.value}\${${e.name}:+:\$${e.name}}\""
        else
          "export ${e.name}=\"${e.value}\"";
      envLines = builtins.concatStringsSep "\n" (map mkEnvLine allEnv);
    in
    ''
      #!/bin/sh
      ${envLines}
      exec /usr/bin/.${binName}-bin "$@"
    '';
}
