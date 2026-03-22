# GTK-specific helpers
#
# Returns shell code for copying GTK runtime assets (GIO modules,
# pixbuf loaders, schemas, typelibs) into the .deb staging tree.
# Key improvements over the monolithic version:
# - Discovers pixbuf loader dir dynamically (no hardcoded 2.10.0)
# - Generates loaders.cache via gdk-pixbuf-query-loaders (not sed)
# - Compiles schemas via glib-compile-schemas on staged tree
{ lib, pkgs }:

{
  mkGtkShellCode =
    {
      pname,
      bundlePath,
      systemLibDir,
      gdkPixbuf,
      librsvg,
      dconfLib,
      gsettingsSchemas,
      gtkPackage,
      typelibPackages ? [ ],
    }:
    ''
      copy_gtk_runtime() {
        echo "==> Copying GTK runtime assets..."

        # --- GIO modules (dconf) ---
        mkdir -p "$LIBDIR/gio/modules"
        # Collect deps from original nix store path BEFORE patchelf changes RPATH
        collect_elf_closure "${dconfLib}/lib/gio/modules/libdconfsettings.so"
        copy_closure_libs
        cp "${dconfLib}/lib/gio/modules/libdconfsettings.so" "$LIBDIR/gio/modules/"
        chmod u+w "$LIBDIR/gio/modules/libdconfsettings.so"
        patchelf --set-rpath '${bundlePath}:${systemLibDir}' \
          "$LIBDIR/gio/modules/libdconfsettings.so" 2>/dev/null || true

        # --- GDK pixbuf loaders (dynamic discovery) ---
        local pixbuf_src_dir
        pixbuf_src_dir=$(find "${gdkPixbuf}/lib/gdk-pixbuf-2.0" -maxdepth 1 -mindepth 1 -type d | head -n1)
        if [ -z "$pixbuf_src_dir" ]; then
          echo "WARNING: Could not find pixbuf loader version dir" >&2
        else
          mkdir -p "$LIBDIR/gdk-pixbuf-2.0/loaders"
          for loader in "$pixbuf_src_dir"/loaders/*.so; do
            [ -f "$loader" ] && cp "$loader" "$LIBDIR/gdk-pixbuf-2.0/loaders/"
          done

          # SVG loader from librsvg
          local rsvg_pixbuf_dir
          rsvg_pixbuf_dir=$(find "${librsvg}/lib/gdk-pixbuf-2.0" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -n1)
          if [ -n "$rsvg_pixbuf_dir" ] && [ -d "$rsvg_pixbuf_dir/loaders" ]; then
            for loader in "$rsvg_pixbuf_dir"/loaders/*.so; do
              [ -f "$loader" ] && cp "$loader" "$LIBDIR/gdk-pixbuf-2.0/loaders/"
            done
          fi

          # Collect deps from ORIGINAL nix store paths before patchelf changes RPATH
          for loader in "$pixbuf_src_dir"/loaders/*.so; do
            [ -f "$loader" ] || continue
            collect_elf_closure "$loader"
            copy_closure_libs
          done
          if [ -n "$rsvg_pixbuf_dir" ] && [ -d "$rsvg_pixbuf_dir/loaders" ]; then
            for loader in "$rsvg_pixbuf_dir"/loaders/*.so; do
              [ -f "$loader" ] || continue
              collect_elf_closure "$loader"
              copy_closure_libs
            done
          fi

          # Fix permissions and RPATH on staged loaders
          for loader in "$LIBDIR"/gdk-pixbuf-2.0/loaders/*.so; do
            [ -f "$loader" ] || continue
            chmod u+w "$loader"
            patchelf --set-rpath '${bundlePath}:${systemLibDir}' "$loader" 2>/dev/null || true
          done

          # Generate loaders.cache via gdk-pixbuf-query-loaders
          GDK_PIXBUF_MODULEDIR="$LIBDIR/gdk-pixbuf-2.0/loaders" \
            "${gdkPixbuf}/bin/gdk-pixbuf-query-loaders" \
            "$LIBDIR"/gdk-pixbuf-2.0/loaders/*.so \
            > "$LIBDIR/gdk-pixbuf-2.0/loaders.cache" 2>/dev/null || {
              echo "WARNING: gdk-pixbuf-query-loaders failed, falling back to sed" >&2
              if [ -f "$pixbuf_src_dir/loaders.cache" ]; then
                sed "s|$pixbuf_src_dir/loaders|${bundlePath}/gdk-pixbuf-2.0/loaders|g" \
                  "$pixbuf_src_dir/loaders.cache" > "$LIBDIR/gdk-pixbuf-2.0/loaders.cache"
              fi
            }
          # Rewrite any remaining nix store paths in the cache
          if [ -f "$LIBDIR/gdk-pixbuf-2.0/loaders.cache" ]; then
            sed -i "s|/nix/store/[^\"]*loaders|${bundlePath}/gdk-pixbuf-2.0/loaders|g" \
              "$LIBDIR/gdk-pixbuf-2.0/loaders.cache"
          fi
        fi

        # --- GSettings schemas ---
        mkdir -p "$SHAREDIR/${pname}-schemas/glib-2.0/schemas"
        cp ${gsettingsSchemas}/share/gsettings-schemas/*/glib-2.0/schemas/*.xml \
          "$SHAREDIR/${pname}-schemas/glib-2.0/schemas/" 2>/dev/null || true
        cp ${gtkPackage}/share/gsettings-schemas/*/glib-2.0/schemas/*.xml \
          "$SHAREDIR/${pname}-schemas/glib-2.0/schemas/" 2>/dev/null || true
        # Strip nix store paths from schema XML before compiling
        find "$SHAREDIR/${pname}-schemas" -name '*.xml' -exec \
          sed -i 's|/nix/store/[^<]*|/usr/share/backgrounds/gnome/placeholder|g' '{}' + 2>/dev/null || true
        # GTK schema support is best-effort for common patterns.
        # Let compilation fail loudly so broken schemas are caught at build time.
        echo "==> Compiling GSettings schemas..."
        "${pkgs.glib.dev}/bin/glib-compile-schemas" \
          "$SHAREDIR/${pname}-schemas/glib-2.0/schemas/"

        # --- GObject introspection typelibs ---
        ${lib.optionalString (typelibPackages != []) ''
          mkdir -p "$LIBDIR/girepository-1.0"
          ${builtins.concatStringsSep "\n" (map (pkg: ''
            if [ -d "${pkg}/lib/girepository-1.0" ]; then
              cp "${pkg}/lib/girepository-1.0"/*.typelib "$LIBDIR/girepository-1.0/" 2>/dev/null || true
            fi
          '') typelibPackages)}
        ''}

        echo "==> GTK runtime assets staged."
      }
    '';
}
