# Platform-aware libao that compiles its audio backends INTO libao.a as built-in
# static drivers, so a fully-static ogg123 has live playback with no dlopen.
#
# Upstream libao ships each backend as a libtool `.la` loadable module dlopen'd
# at runtime from lib/ao/plugins-4/. Under static musl/mingw, dlopen is a no-op
# (audio_out.c stubs it), so only the compiled-in `static_drivers[]` table is
# reachable. We therefore wrap each backend's plugin source — renaming its
# generic `ao_plugin_*` exports to `ao_<drv>_*` (so several co-link without
# colliding), #including the source, and synthesising the built-in
# `ao_functions ao_<drv>` table — add it to libao_la_SOURCES, and register it in
# static_drivers[]. Selection is by ao_info.priority: pulse(50) > alsa(35) >
# oss(20) on Linux; macosx(30) on Darwin. (Windows uses libao's already-built-in
# WMM driver — no surgery — handled in flake.nix's mingw path.)
#
#   Linux  : pulse (socket→pipewire/pulse daemon) + alsa (hw/dmix) + oss (/dev/dsp)
#   Darwin : macosx (CoreAudio), linking the system AudioUnit/CoreAudio frameworks
#
# `ps` is a pkgsStatic-like scope (the native target). Returns the libao deriv.
{ lib }:
ps:
let
  isDarwin = ps.stdenv.hostPlatform.isDarwin or false;

  # ---- static libpulse client (Linux) -------------------------------------
  # Recipe: reference-static-libpulse-client-recipe. daemon/dbus/glib/oss-output
  # off + shared_library→library so the client libs build as .a under the static
  # crt. Talks the native protocol over the unix socket; no dlopen, no daemon.
  libpulse = ps.libpulseaudio.overrideAttrs (o: {
    meta = (o.meta or { }) // { badPlatforms = [ ]; };
    mesonFlags = (o.mesonFlags or [ ]) ++ [
      "-Dclient=true"
      "-Ddaemon=false"
      "-Dtests=false"
      "-Doss-output=disabled"
      "-Ddbus=disabled"
      "-Dglib=disabled"
    ];
    postPatch = (o.postPatch or "") + ''
      substituteInPlace src/meson.build \
        --replace-fail "libpulsecommon = shared_library(" "libpulsecommon = library("
      substituteInPlace src/pulse/meson.build \
        --replace-fail "libpulse = shared_library(" "libpulse = library(" \
        --replace-fail "libpulse_simple = shared_library(" "libpulse_simple = library(" \
        --replace-fail "libpulse_mainloop_glib = shared_library(" "libpulse_mainloop_glib = library("
    '';
  });

  # ---- built-in-driver wrapper generator ----------------------------------
  baseSyms = [
    "test"
    "driver_info"
    "device_init"
    "set_option"
    "open"
    "play"
    "close"
    "device_clear"
    "file_extension"
  ];
  # `drv` = plugin dir/file stem; `syms` = the ao_plugin_* names it defines.
  mkWrap = drv: syms: ps.writeText "ao_${drv}_static.c" (
    (lib.concatMapStrings (s: "#define ao_plugin_${s} ao_${drv}_${s}\n") syms)
    + ''
      #include "plugins/${drv}/ao_${drv}.c"
      ao_functions ao_${drv} = {
        ao_${drv}_test, ao_${drv}_driver_info, ao_${drv}_device_init,
        ao_${drv}_set_option, ao_${drv}_open, ao_${drv}_play,
        ao_${drv}_close, ao_${drv}_device_clear, 0
      };
    ''
  );

  # Per-platform driver list (each: name → the ao_plugin_* symbols it defines).
  drivers =
    if isDarwin then [
      { name = "macosx"; syms = baseSyms; }
    ] else [
      { name = "pulse"; syms = baseSyms; }
      { name = "alsa"; syms = baseSyms ++ [ "playi" ]; }
      { name = "oss"; syms = baseSyms; }
    ];

  wrapFiles = lib.concatMapStringsSep "\n"
    (d: "cp ${mkWrap d.name d.syms} src/ao_${d.name}_static.c")
    drivers;
  wrapSourceList = lib.concatMapStringsSep " " (d: "ao_${d.name}_static.c") drivers;
  externLine = lib.concatMapStrings (d: "extern ao_functions ao_${d.name}; ") drivers;
  arrayEntries = lib.concatMapStrings (d: "\n    \t&ao_${d.name},") drivers;

  # ao.pc additions so a static consumer (vorbis-tools' configure → pkg-config)
  # resolves the backend closure. Linux: Requires.private chains libpulse/alsa.
  # Darwin: the CoreAudio frameworks ride in Libs.private.
  pcEdit =
    if isDarwin then ''
      substituteInPlace ao.pc.in \
        --replace-fail "Libs.private: @LIBS@" \
          "Libs.private: @LIBS@ -framework AudioUnit -framework CoreAudio -framework CoreServices"
    '' else ''
      substituteInPlace ao.pc.in \
        --replace-fail "Conflicts:" "Requires.private: libpulse-simple alsa
      Conflicts:"
    '';

  extraConfigure = lib.optionals (!isDarwin) [ "--enable-pulse" ];
  # On Linux, ao.pc's Requires.private needs libpulse/alsa .pc reachable in the
  # consumer's PKG_CONFIG_PATH; pkgsStatic only auto-propagates `out` (the .pc is
  # in `.dev`) → propagate .dev explicitly (the pkgsStatic-multi-output trap).
  extraPropagated = lib.optionals (!isDarwin) [
    libpulse
    libpulse.dev
    ps.alsa-lib
    ps.alsa-lib.dev
  ];
  extraBuildInputs = lib.optionals (!isDarwin) [ libpulse libpulse.dev ];
in
ps.libao.overrideAttrs (o: {
  buildInputs = (o.buildInputs or [ ]) ++ extraBuildInputs;
  propagatedBuildInputs = (o.propagatedBuildInputs or [ ]) ++ extraPropagated;
  configureFlags = (o.configureFlags or [ ]) ++ extraConfigure;
  meta = (o.meta or { }) // { platforms = lib.platforms.all; broken = false; };
  postPatch = (o.postPatch or "") + ''
    ${wrapFiles}

    substituteInPlace src/Makefile.am \
      --replace-fail \
        "libao_la_SOURCES = audio_out.c config.c ao_null.c ao_wav.c ao_au.c ao_raw.c ao_aixs.c \$(wmm)" \
        "libao_la_SOURCES = audio_out.c config.c ao_null.c ao_wav.c ao_au.c ao_raw.c ao_aixs.c \$(wmm) ${wrapSourceList}"

    substituteInPlace src/audio_out.c \
      --replace-fail \
        "static ao_functions *static_drivers[] = {" \
        "${externLine}static ao_functions *static_drivers[] = {${arrayEntries}"

    ${pcEdit}
  '';
})
