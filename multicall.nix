# vorbis-tools ships six command-line programs — ogg123 (play), oggenc (encode),
# oggdec (decode), ogginfo (inspect), vcut (split) and vorbiscomment (tag). To
# honour the unpins one-pkg-one-bin rule we post-link them into a single
# multicall binary at $out/bin/vorbis-tools (a busybox-style dispatcher named
# after the package, since unpins/action-build resolves result/bin/<package_name>);
# `lib.withAliases` then embeds the six tool names as UNPIN_META aliases so unpin
# recreates the argv[0] shims. The bare `vorbis-tools` name isn't a real tool, so
# it falls through to the flagship player (ogg123).
#
# Why a post-link route (no source patch): the six tools are separate automake
# programs in their own subdirs, each a plain (non-libtool) `$(CC) … -o <tool>
# <objs> <libs>` link sharing the heavy static archives (libvorbis*/libogg/
# libFLAC/libspeex and, for ogg123, libao+pulse/alsa/oss+curl). Same-named globals
# in the per-tool objects (each tool has its own `main`, and duplicate-named
# sources like audio.c/utf8.c recur across dirs) would collide on a naive merge.
# So we reuse the proven ld-free rename recipe (cf. opus-tools/flac): per tool,
# build ONE redef map (main → <tool>_main, every other strong defined global foo →
# <tool>__foo) from the tool's raw objects and objcopy it onto each object in
# place — objcopy rewrites the definition AND every relocation, so each tool stays
# internally consistent and its symbols no longer clash. The renamed raw objects,
# not an `ld -r` partial, go into the final link (ld64's `-r` would demote a `main`
# owning function-local statics from global T to local t, emptying the map). The
# shared archives are linked ONCE at the end, so the binary carries one copy of
# each codec lib, not six.
#
# As with opus-tools, vorbis-tools is autotools with no link.txt; we capture each
# tool's real link command by removing the binaries and relinking with `make V=1`,
# then parse that command for the tool's objects and its -l/-L/archive tokens. The
# exact link list configure produced is reused verbatim on every platform (musl
# ELF / Mach-O / mingw).
#
# The audio backend is wired into libao by the caller (see ./audio.nix): on Linux
# pulse/alsa/oss are compiled into libao.a as built-in static drivers; on Darwin
# the macosx CoreAudio driver; on Windows libao's already-built-in WMM driver
# carries playback (mingw has no dlopen, so only static_drivers[] is reachable).
#
# isDarwin/isWindows come from the INPUT derivation's stdenv (under windowsBuild
# the outer `pkgs` is the x86_64-linux root — the cross lives inside the input).
{ lib }:
{ pkgs, vorbisTools }:
let
  isDarwin = vorbisTools.stdenv.hostPlatform.isDarwin or false;
  isWindows = vorbisTools.stdenv.hostPlatform.isWindows or false;

  multicall = vorbisTools.overrideAttrs (old: {
    pname = "vorbis-tools-multi";
    outputs = [ "out" ];

    # We re-link the tools ourselves and smoke-test the result; skip upstream
    # checks that would run a single tool we're replacing.
    doCheck = false;
    doInstallCheck = false;

    postBuild = (old.postBuild or "") + ''
      set -e
      mkdir -p mc
      TOOLS="ogg123 oggenc oggdec ogginfo vcut vorbiscomment"

      # Capture each tool's real link command (autotools' analog of CMake's
      # link.txt). Each program is a plain (non-libtool) automake target in its
      # OWN subdir (ogg123/ogg123, oggenc/oggenc, …) linked with a single
      # `$(CC) … -o <tool> <objs> <libs>` line. Relink verbosely FROM WITHIN each
      # subdir (so the binary name doesn't collide with the same-named dir at top
      # level, and objects/archives resolve relative to the subdir). A bare `make`
      # there relinks the removed binary (objects already up to date) and works on
      # mingw where the real target carries $(EXEEXT).
      ROOT=$PWD

      # From a link line, the objects are the *.o / *.obj tokens; the libraries
      # are the -l / -L / *.a / -pthread / -framework tokens, harvested into the
      # shared link list (dedup first-seen, dependency-correct order). Drop the
      # configure-added hardening LDFLAGS (-pie, -Wl,-z,relro, -Wl,-z,now): they
      # are irrelevant to the merged binary and -pie clashes with the `-static`
      # runtime fold on the mingw link. Object/relative-archive tokens are
      # resolved against the tool's subdir (passed as $1).
      LIBS=""
      addlib() { case " $LIBS " in *" $1 "*) ;; *) LIBS="$LIBS $1" ;; esac; }
      fw=""
      classify() {
        local dir="$1" tok="$2"
        if [ -n "$fw" ]; then LIBS="$LIBS -framework $tok"; fw=""; return; fi
        case "$tok" in
          *.dll.a)              ;;
          -framework)           fw=1 ;;
          -l* | -L* | -pthread) addlib "$tok" ;;
          /*.a)                 addlib "$tok" ;;
          *.a)                  addlib "$(cd "$dir" && realpath -m "$tok")" ;;
        esac
      }

      declare -A TOBJ
      for t in $TOOLS; do
        ( cd "$t" && rm -f "$t" "$t.exe" && make V=1 ) > "mc/$t.log" 2>&1 \
          || { cat "mc/$t.log"; exit 1; }
        line=$(awk -v t="$t" '
          $0 ~ ("-o (\\./)?" t "(\\.exe)?( |$)") && $0 !~ / -c / { last=$0 } END{ print last }
        ' "mc/$t.log")
        [ -n "$line" ] || { echo "no link line for $t"; cat "mc/$t.log"; exit 1; }
        objs=""
        for tok in $line; do
          case "$tok" in
            *.o | *.obj) objs="$objs $ROOT/$t/$tok" ;;
            *)           classify "$t" "$tok" ;;
          esac
        done
        TOBJ[$t]="$objs"
      done

      # Mach-O leads C symbols with '_'; detect once from ogg123's objects.
      if $NM --defined-only ''${TOBJ[ogg123]} 2>/dev/null | awk '$3=="_main"{f=1} END{exit !f}'; then
        up=_
      else
        up=""
      fi

      # Per tool: one redef map (main → <t>_main, other strong defined globals
      # foo → <t>__foo; skip weak/COMDAT W/V and names containing '.'), applied to
      # each of that tool's raw objects so refs follow the rename and the tools'
      # duplicated globals never collide.
      MCOBJS=""
      for t in $TOOLS; do
        $NM --defined-only ''${TOBJ[$t]} 2>/dev/null \
          | awk -v t="$t" -v up="$up" '
              $2 ~ /^[A-TX-Z]$/ && $2 != "W" && $2 != "V" {
                sym = $3; core = sym
                if (up != "" && index(core, up) == 1) core = substr(core, 2)
                if (index(core, ".") != 0) next
                if (core !~ /^[A-Za-z_][A-Za-z0-9_]*$/) next
                if (core == "main") print sym " " up t "_main"
                else                print sym " " up t "__" core
              }' | sort -u > "mc/$t.redef"
        for o in ''${TOBJ[$t]}; do
          d="mc/$t.$(echo "$o" | tr '/' '_')"
          cp "$o" "$d"
          [ -s "mc/$t.redef" ] && $OBJCOPY --redefine-syms="mc/$t.redef" "$d"
          MCOBJS="$MCOBJS $d"
        done
      done

      # Dispatcher (shared canonical generator — see nix-lib
      # lib.multicallDispatcherC). Applet list from multicall/apps.list ($TOOLS);
      # a bare/unknown invocation runs ogg123 (defaultApplet) so the
      # `--version` smoke reaches ogg123_main and a renamed copy still dispatches.
      mkdir -p multicall
      printf '%s\n' $TOOLS > multicall/apps.list
${lib.multicallDispatcherC { name = "vorbis-tools"; defaultApplet = "ogg123"; }}
      $CC -O2 -c -o multicall/dispatcher.o multicall/dispatcher.c

      # Final link: shared archives, once. On GNU-ld targets wrap them in a group
      # to absorb back-references; ld64 (darwin) rejects --start-group but
      # re-scans archives on its own, so list them plain there.
      if ${if isDarwin then "true" else "false"}; then
        GO=""; GC=""
      else
        GO="-Wl,--start-group"; GC="-Wl,--end-group"
      fi
      # mingw: this manual link bypasses the `-static` the normal mingwStaticCross
      # build applies. Link the runtime fully static so every -l resolves to its
      # .a and only real Windows system DLLs remain next to the .exe.
      MCF=""
      ${lib.optionalString isWindows ''MCF="-static"''}
      $CC -O2 \
        $MCOBJS multicall/dispatcher.o \
        $GO $LIBS $GC -lm $MCF \
        -o mc/vorbis-tools
      [ -f mc/vorbis-tools ] || mv mc/vorbis-tools.exe mc/vorbis-tools
    '';

    installPhase = ''
      runHook preInstall
      mkdir -p "$out/bin" "$out/share/man/man1"
      # Canonical binary is named after the package (vorbis-tools) — a
      # busybox-style dispatcher that action-build resolves as
      # result/bin/<package_name>; the six tools are symlinks that
      # lib.withAliases turns into argv[0] aliases.
      install -m755 mc/vorbis-tools "$out/bin/vorbis-tools"
      for t in ogg123 oggenc oggdec ogginfo vcut vorbiscomment; do
        ln -s vorbis-tools "$out/bin/$t"
      done

      # Man pages ship as source, in per-tool dirs (oggenc's lives in man/).
      # Install all six so the set matches nixpkgs' vorbis-tools man output.
      for t in ogg123 oggenc oggdec ogginfo vcut vorbiscomment; do
        for cand in "$t/$t.1" "$t/man/$t.1" "$src/$t/$t.1"; do
          [ -f "$cand" ] && { cp "$cand" "$out/share/man/man1/$t.1"; break; }
        done
      done
      runHook postInstall
    '';
  });

  aliased = lib.withAliases pkgs
    {
      primary = "vorbis-tools";
      aliasesFromSymlinksIn = "bin";
    }
    multicall;
in
if isWindows
then aliased.overrideAttrs (o: {
  postFixup = (o.postFixup or "") + ''
    [ -f "$out/bin/vorbis-tools" ] && mv "$out/bin/vorbis-tools" "$out/bin/vorbis-tools.exe"
  '';
})
else aliased
