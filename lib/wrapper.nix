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
      discoverModules ? false,
      pname ? binName,
      extraWrapperEnv ? [ ],
    }:
    let
      mkEnvLine =
        e:
        if e.append or false then
          "export ${e.name}=\"${e.value}\${${e.name}:+:\$${e.name}}\""
        else
          "export ${e.name}=\"${e.value}\"";
      extraEnvLines = builtins.concatStringsSep "\n" (map mkEnvLine extraWrapperEnv);
      gtkEnvLines = builtins.concatStringsSep "\n" (
        lib.optionals gtkSupport [
          ''
            if [ -d "${bundlePath}/gio/modules" ]; then
              export GIO_EXTRA_MODULES="${bundlePath}/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
            fi
          ''
          ''
            if [ -f "${bundlePath}/gdk-pixbuf-2.0/loaders.cache" ]; then
              export GDK_PIXBUF_MODULE_FILE="${bundlePath}/gdk-pixbuf-2.0/loaders.cache"
            fi
          ''
          ''
            if [ -d "/usr/share/${pname}-schemas" ]; then
              export XDG_DATA_DIRS="/usr/share/${pname}-schemas:/usr/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
            fi
          ''
          ''
            if [ -d "${bundlePath}/girepository-1.0" ]; then
              export GI_TYPELIB_PATH="${bundlePath}/girepository-1.0''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
            fi
          ''
        ]
      );
      discoverEnvLines = builtins.concatStringsSep "\n" (
        lib.optionals (discoverModules && !gtkSupport) [
          ''
            if [ -d "${bundlePath}/gio/modules" ]; then
              export GIO_EXTRA_MODULES="${bundlePath}/gio/modules''${GIO_EXTRA_MODULES:+:$GIO_EXTRA_MODULES}"
            fi
          ''
          ''
            if [ -f "${bundlePath}/gdk-pixbuf-2.0/loaders.cache" ]; then
              export GDK_PIXBUF_MODULE_FILE="${bundlePath}/gdk-pixbuf-2.0/loaders.cache"
            fi
          ''
          ''
            if [ -d "/usr/share/${pname}-schemas" ]; then
              export XDG_DATA_DIRS="/usr/share/${pname}-schemas:/usr/share''${XDG_DATA_DIRS:+:$XDG_DATA_DIRS}"
            fi
          ''
          ''
            if [ -d "${bundlePath}/girepository-1.0" ]; then
              export GI_TYPELIB_PATH="${bundlePath}/girepository-1.0''${GI_TYPELIB_PATH:+:$GI_TYPELIB_PATH}"
            fi
          ''
        ]
        ++ lib.optionals discoverModules [
          ''
            if [ -d "${bundlePath}/gstreamer-1.0" ]; then
              export GST_PLUGIN_PATH="${bundlePath}/gstreamer-1.0''${GST_PLUGIN_PATH:+:$GST_PLUGIN_PATH}"
            fi
          ''
          ''
            if [ -r "${bundlePath}/.qt-major" ]; then
              case "$(cat "${bundlePath}/.qt-major")" in
                6)
                  if [ -d "${bundlePath}/qt6/plugins" ]; then
                    export QT_PLUGIN_PATH="${bundlePath}/qt6/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
                  fi
                  ;;
                5)
                  if [ -d "${bundlePath}/qt5/plugins" ]; then
                    export QT_PLUGIN_PATH="${bundlePath}/qt5/plugins''${QT_PLUGIN_PATH:+:$QT_PLUGIN_PATH}"
                  fi
                  ;;
              esac
            fi
          ''
        ]
      );
    in
    ''
      #!/bin/sh
      ${gtkEnvLines}
      ${discoverEnvLines}
      ${extraEnvLines}
      exec /usr/bin/.${binName}-bin "$@"
    '';
}
