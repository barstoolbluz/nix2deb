{ lib, pkgs }:

{
  mkDiscoverShellCode =
    {
      pname,
      bundlePath,
      gtkSupport ? false,
      discoverModuleCategories ? null,
    }:
    let
      enabled = category: discoverModuleCategories == null || lib.elem category discoverModuleCategories;
      enabledTypelib = enabled "typelib" || enabled "typelibs";
    in
    ''
      _copy_data_file_safe() {
        local src="$1" dst="$2"
        local dst_dir
        dst_dir=$(dirname "$dst")
        mkdir -p "$dst_dir"

        if [ -e "$dst" ] || [ -L "$dst" ]; then
          if [ -f "$dst" ] && [ -f "$src" ] && ! cmp -s "$src" "$dst"; then
            echo "  WARN: asset collision for $(basename "$dst"), keeping first copy" >&2
            echo "    Existing: $dst" >&2
            echo "    Skipping: $src" >&2
          fi
          return 0
        fi

        cp "$src" "$dst"
      }

      _discover_copy_elf_module() {
        local src="$1" dst_dir="$2"
        local target

        mkdir -p "$dst_dir"
        collect_elf_closure "$src"
        copy_closure_libs
        target=$(basename "$src")
        _copy_lib_safe "$src" "$dst_dir/$target"
      }

      discover_dlopen_modules() {
        echo "==> Discovering dlopen modules from ELF closure..."

        local -A _DISCOVER_SCANNED_PKG_DIRS
        local -A _DISCOVER_SEEN_ELF
        local -A _DISCOVER_SEEN_TYPELIBS
        local -A _DISCOVER_SEEN_SCHEMAS

        local gio_count=0
        local pixbuf_count=0
        local qt5_count=0
        local qt6_count=0
        local gstreamer_count=0
        local typelib_count=0
        local schema_count=0
        local scanned_pkg_count=0
        local nullglob_was_set=0

        shopt -q nullglob && nullglob_was_set=1 || true
        shopt -s nullglob

        while :; do
          local progressed=0
          local -a pkg_dir_snapshot
          mapfile -t pkg_dir_snapshot < <(printf '%s\n' "''${!_CLOSURE_PKG_DIRS[@]}" | LC_ALL=C sort -u)

          for pkg_dir in "''${pkg_dir_snapshot[@]}"; do
            [ -n "$pkg_dir" ] || continue
            [ -d "$pkg_dir" ] || continue
            [ -n "''${_DISCOVER_SCANNED_PKG_DIRS[$pkg_dir]+x}" ] && continue

            _DISCOVER_SCANNED_PKG_DIRS["$pkg_dir"]=1
            progressed=1
            scanned_pkg_count=$((scanned_pkg_count + 1))

            ${lib.optionalString (!gtkSupport && enabled "gio") ''
              for module in "$pkg_dir"/lib/gio/modules/*.so; do
                [ -f "$module" ] || continue
                local real_module
                real_module=$(readlink -f "$module" 2>/dev/null) || real_module="$module"
                [ -n "''${_DISCOVER_SEEN_ELF[$real_module]+x}" ] && continue
                _DISCOVER_SEEN_ELF["$real_module"]=1
                _discover_copy_elf_module "$module" "$LIBDIR/gio/modules"
                gio_count=$((gio_count + 1))
              done
            ''}

            ${lib.optionalString (!gtkSupport && enabled "pixbuf") ''
              for module in "$pkg_dir"/lib/gdk-pixbuf-2.0/*/loaders/*.so; do
                [ -f "$module" ] || continue
                local real_module
                real_module=$(readlink -f "$module" 2>/dev/null) || real_module="$module"
                [ -n "''${_DISCOVER_SEEN_ELF[$real_module]+x}" ] && continue
                _DISCOVER_SEEN_ELF["$real_module"]=1
                _discover_copy_elf_module "$module" "$LIBDIR/gdk-pixbuf-2.0/loaders"
                pixbuf_count=$((pixbuf_count + 1))
              done
            ''}

            ${lib.optionalString (enabled "qt5" || enabled "qt6") ''
              for module in \
                "$pkg_dir"/lib/qt5/plugins/*/*.so \
                "$pkg_dir"/lib/qt-5*/plugins/*/*.so \
                "$pkg_dir"/lib/qt6/plugins/*/*.so \
                "$pkg_dir"/lib/qt-6*/plugins/*/*.so
              do
                [ -f "$module" ] || continue
                local real_module category dst_dir
                real_module=$(readlink -f "$module" 2>/dev/null) || real_module="$module"
                [ -n "''${_DISCOVER_SEEN_ELF[$real_module]+x}" ] && continue
                category=$(basename "$(dirname "$module")")

                case "$module" in
                  "$pkg_dir"/lib/qt5/plugins/*/*.so|"$pkg_dir"/lib/qt-5*/plugins/*/*.so)
                    ${
                      if enabled "qt5" then
                        ''
                          dst_dir="$LIBDIR/qt5/plugins/$category"
                          _DISCOVER_SEEN_ELF["$real_module"]=1
                          _discover_copy_elf_module "$module" "$dst_dir"
                          qt5_count=$((qt5_count + 1))
                        ''
                      else
                        ''
                          continue
                        ''
                    }
                    ;;
                  "$pkg_dir"/lib/qt6/plugins/*/*.so|"$pkg_dir"/lib/qt-6*/plugins/*/*.so)
                    ${
                      if enabled "qt6" then
                        ''
                          dst_dir="$LIBDIR/qt6/plugins/$category"
                          _DISCOVER_SEEN_ELF["$real_module"]=1
                          _discover_copy_elf_module "$module" "$dst_dir"
                          qt6_count=$((qt6_count + 1))
                        ''
                      else
                        ''
                          continue
                        ''
                    }
                    ;;
                esac
              done
            ''}

            ${lib.optionalString (enabled "gstreamer") ''
              for module in "$pkg_dir"/lib/gstreamer-1.0/*.so; do
                [ -f "$module" ] || continue
                local real_module
                real_module=$(readlink -f "$module" 2>/dev/null) || real_module="$module"
                [ -n "''${_DISCOVER_SEEN_ELF[$real_module]+x}" ] && continue
                _DISCOVER_SEEN_ELF["$real_module"]=1
                _discover_copy_elf_module "$module" "$LIBDIR/gstreamer-1.0"
                gstreamer_count=$((gstreamer_count + 1))
              done
            ''}

            ${lib.optionalString (!gtkSupport && enabledTypelib) ''
              for typelib in "$pkg_dir"/lib/girepository-1.0/*.typelib; do
                [ -f "$typelib" ] || continue
                local real_typelib target
                real_typelib=$(readlink -f "$typelib" 2>/dev/null) || real_typelib="$typelib"
                [ -n "''${_DISCOVER_SEEN_TYPELIBS[$real_typelib]+x}" ] && continue
                _DISCOVER_SEEN_TYPELIBS["$real_typelib"]=1
                target="$LIBDIR/girepository-1.0/$(basename "$typelib")"
                _copy_data_file_safe "$typelib" "$target"
                typelib_count=$((typelib_count + 1))
              done
            ''}

            ${lib.optionalString (!gtkSupport && enabled "schemas") ''
              for schema in "$pkg_dir"/share/gsettings-schemas/*/glib-2.0/schemas/*.xml; do
                [ -f "$schema" ] || continue
                local real_schema target
                real_schema=$(readlink -f "$schema" 2>/dev/null) || real_schema="$schema"
                [ -n "''${_DISCOVER_SEEN_SCHEMAS[$real_schema]+x}" ] && continue
                _DISCOVER_SEEN_SCHEMAS["$real_schema"]=1
                target="$SHAREDIR/${pname}-schemas/glib-2.0/schemas/$(basename "$schema")"
                _copy_data_file_safe "$schema" "$target"
                schema_count=$((schema_count + 1))
              done
            ''}
          done

          [ "$progressed" -eq 1 ] || break
        done

        [ "$nullglob_was_set" -eq 1 ] || shopt -u nullglob

        ${lib.optionalString (!gtkSupport && enabled "pixbuf") ''
          if [ "$pixbuf_count" -gt 0 ]; then
            echo "==> Generating gdk-pixbuf loaders.cache..."
            mkdir -p "$LIBDIR/gdk-pixbuf-2.0"
            GDK_PIXBUF_MODULEDIR="$LIBDIR/gdk-pixbuf-2.0/loaders" \
              "${pkgs.gdk-pixbuf}/bin/gdk-pixbuf-query-loaders" \
              "$LIBDIR"/gdk-pixbuf-2.0/loaders/*.so \
              > "$LIBDIR/gdk-pixbuf-2.0/loaders.cache" 2>/dev/null || {
                echo "ERROR: gdk-pixbuf-query-loaders failed during module discovery" >&2
                exit 1
              }
            sed -i "s|/nix/store/[^\"]*loaders|${bundlePath}/gdk-pixbuf-2.0/loaders|g" \
              "$LIBDIR/gdk-pixbuf-2.0/loaders.cache"
          fi
        ''}

        ${lib.optionalString (!gtkSupport && enabled "schemas") ''
          if [ "$schema_count" -gt 0 ]; then
            echo "==> Compiling discovered GSettings schemas..."
            find "$SHAREDIR/${pname}-schemas" -name '*.xml' -exec \
              sed -i 's|/nix/store/[^<]*/share/|/usr/share/|g' '{}' + 2>/dev/null || true
            find "$SHAREDIR/${pname}-schemas" -name '*.xml' -exec \
              sed -i 's|/nix/store/[^<]*/|/usr/|g' '{}' + 2>/dev/null || true
            "${pkgs.glib.dev}/bin/glib-compile-schemas" \
              "$SHAREDIR/${pname}-schemas/glib-2.0/schemas/"
          fi
        ''}

        scrub_elf_nix_refs "$LIBDIR"

        if [ "$scanned_pkg_count" -eq 0 ]; then
          echo "  No closure package roots were recorded during ELF bundling."
        fi

        echo "  GIO modules discovered: $gio_count"
        echo "  Pixbuf loaders discovered: $pixbuf_count"
        echo "  Qt5 plugins discovered: $qt5_count"
        echo "  Qt6 plugins discovered: $qt6_count"
        echo "  GStreamer plugins discovered: $gstreamer_count"
        echo "  Typelibs discovered: $typelib_count"
        echo "  GSettings schemas discovered: $schema_count"
        echo "==> dlopen() module discovery complete."
      }
    '';
}
