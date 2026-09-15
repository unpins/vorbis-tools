{
  description = "vorbis-tools (ogg123 player + Ogg Vorbis utilities) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # vorbis-tools installs six CLIs — ogg123 (play), oggenc (encode), oggdec
  # (decode), ogginfo (inspect), vcut (split) and vorbiscomment (tag); the
  # engine self-folds them into one `vorbis-tools` dispatcher binary with each
  # tool as an argv[0]-dispatch UNPIN_META alias. The canonical binary is named
  # `vorbis-tools` (the package name) to match unpins/action-build's
  # result/bin/<package_name> contract; that name is not itself a tool, so a
  # bare invocation lists the six.
  #
  # The hard part is live audio in a fully-static binary. libao ships its audio
  # backends as dlopen plugins, dead under static musl/mingw — so ./audio.nix
  # compiles them INTO libao.a as built-in static drivers (recipe:
  # reference-libao-static-builtin-drivers + reference-static-libpulse-client-recipe):
  #   Linux   → pulse (socket→pipewire/pulse daemon) + alsa + oss
  #   Darwin  → macosx (CoreAudio frameworks)
  #   Windows → libao's already-built-in WMM driver (mingw has no dlopen, so the
  #             compiled-in static_drivers[] is all there is — WMM rides for free)
  #
  # `--disable-nls` drops the bundled gettext `intl/` subdir, which fails to build
  # its libintl.a under musl; the CLIs need no translated messages.
  outputs = { self, unpins-lib }:
    let
      ulib = unpins-lib.lib;
      # Per-dep fixes for the audio closure ogg123 drags in under the engine
      # (libao → libpulse → {fftw, dbus → libX11}; libsndfile → {lame,
      # libmpg123}). Every one of these is the same breakage sox hit migrating
      # the same chain. Only the Linux playback path pulls libpulse, so off
      # Linux this is effectively identity.
      withCodecFixes = ps: ps.extend (final: prev: {
        # libX11 (pulled on Linux via libao's playback chain, libpulseaudio →
        # dbus → libX11) probes whether its cpp needs -undef to stop predefining
        # `unix`. The engine's clang cpp keeps `unix` defined even under -undef,
        # so the probe aborts ("defines unix with or without -undef. I don't know
        # what to do."). RAWCPP only preprocesses X11's host-independent locale/
        # compose text at build time, so hand it the build-host gcc cpp; libX11
        # links in as a plain static .a regardless of which cpp cooked its data.
        # Same fix sox/ddcutil use. Inert on darwin (no X11 in the CoreAudio path).
        libx11 = prev.libx11.overrideAttrs (_: {
          RAWCPP = "${final.buildPackages.stdenv.cc}/bin/cpp";
        });
        # fftw (single, pulled via libpulseaudio's equalizer module) forces
        # --enable-openmp and links llvmPackages.openmp, but the engine's
        # self-contained clang has no OpenMP runtime → configure aborts ("don't
        # know how to enable OpenMP"). The OpenMP variant (libfftw3f_omp) is
        # unused — pulseaudio links the serial libfftw3f — so drop OpenMP and keep
        # pthreads threading. Same fix sox uses.
        fftwFloat = prev.fftwFloat.overrideAttrs (o: {
          configureFlags = final.lib.filter (f: f != "--enable-openmp")
            (o.configureFlags or [ ]);
          buildInputs = final.lib.filter (d: (d.pname or "") != "openmp")
            (o.buildInputs or [ ]);
        });
        # lame's `#ifdef HAVE_XMMINTRIN_H` SSE paths (libmp3lame/vector/… use
        # `__m128`) don't compile on the i686 target's -march=i686 baseline (no
        # SSE). configure defines HAVE_XMMINTRIN_H anyway: its probe compiles
        # `_mm_sfence()` with clang's *default* i686 flags (SSE2-capable) BEFORE
        # lame appends -march=i686 to CFLAGS, so it passes where the real compile
        # fails (gcc doesn't false-positive here). Undefine it post-configure —
        # every SSE block then takes its scalar fallback (what ARM/PPC already
        # use; MP3 output unchanged). Gated to i686. Same fix sox uses.
        lame = if final.stdenv.hostPlatform.isx86_32
          then prev.lame.overrideAttrs (o: {
            postConfigure = (o.postConfigure or "") + ''
              sed -i '/#define HAVE_XMMINTRIN_H 1/d' config.h
            '';
          })
          else prev.lame;
        # libvorbis' 32-bit-x86 CFLAGS case hardcodes `-mno-ieee-fp`, a GCC-only
        # flag the engine clang rejects as a fatal unknown argument (x86_64 takes
        # a different case). It only relaxes IEEE FP strictness for -ffast-math
        # (already on); drop it so i686 compiles. Gated so other arches keep their
        # hash. Same fix sox uses.
        libvorbis = if final.stdenv.hostPlatform.isx86_32
          then prev.libvorbis.overrideAttrs (o: {
            postPatch = (o.postPatch or "") + ''
              substituteInPlace configure --replace-fail ' -mno-ieee-fp' ""
            '';
          })
          else prev.libvorbis;
        # libmpg123 (pulled by libsndfile for MP3 decode) builds its mpg123/
        # out123 CLI programs even under nixpkgs' libOnly (that only drops the
        # audio backends). Those programs fail the engine's whole-program LTO link
        # (ld.lld: undefined symbol `fputs`), and we don't ship them — libsndfile
        # needs only libmpg123.a. Select just that component so the offending link
        # never happens; the decode library is unchanged.
        libmpg123 = prev.libmpg123.overrideAttrs (o: {
          configureFlags = (o.configureFlags or [ ])
            ++ [ "--disable-components" "--enable-libmpg123" ];
          # With only the library built there are no man pages, so the recipe's
          # declared `man` output would be empty and nix errors.
          postInstall = (o.postInstall or "") + ''
            mkdir -p "$man"
          '';
        });
        # libopus (pulled on every target by opusfile, below) needs the arm64
        # meson-intrinsics fix on native aarch64-darwin. Gated so the other
        # targets keep their hash. Same nativeFixes.libopus sox and opus-tools use.
        libopus = if final.stdenv.hostPlatform.isDarwin
          then ulib.nativeFixes.libopus prev
          else prev.libopus;
      });
      # The engine self-fold's auto-derived `depInputDirs` globs each dep's
      # `lib/*.a`, but libpulseaudio ships its internal `libpulsecommon-<ver>.a`
      # one level down in `lib/pulseaudio/` — so the pa_* symbols ogg123 pulls
      # (pa_run_once, pa_hashmap_*, …) would be undefined at the LTO link. Name
      # that nested archive explicitly as a depArchive, reusing the SAME static
      # libpulse audio.nix bakes into libao (exposed via passthru), so the bytes
      # match the build's input closure.
      pulseCommonArchive = ps:
        let lp = (import ./audio.nix { lib = ps.lib // ulib; } ps).libpulse;
        in "${lp}/lib/pulseaudio/libpulsecommon-${lp.version}.a";

      # Bugs in vorbis-tools 1.4.3 itself, fixed for every target (the glibc
      # build in nixpkgs has them too):
      #   - oggenc never recognized an Ogg FLAC input, and crashed on any input
      #     it didn't recognize;
      #   - ogg123 printed Speex playback times from an uninitialized sample
      #     count, overflowing a 20-byte buffer;
      #   - the tools parse numbers with the user's locale, so where the decimal
      #     separator is a comma `oggenc -q 4.5` encoded at quality 4 and
      #     `vcut in.ogg a.ogg b.ogg +0.5` cut at 0, silently. LC_NUMERIC stays
      #     "C"; the locale still selects the character set, which is what the
      #     tools need it for.
      #
      # And one in how it is built: configure looks for a program named plain
      # `pkg-config`, which a cross build (musl and mingw alike) only has with the
      # target prefix, so it skipped every pkg-config check without an error —
      # dropping Opus playback and ogg123's Vorbis filter (ReplayGain, volume
      # scaling). The pkg-config it would use is the one the build provides.
      sourceFixes = o: {
        configureFlags = (o.configureFlags or [ ]) ++ [ "ac_cv_prog_HAVE_PKG_CONFIG=yes" ];
        patches = (o.patches or [ ]) ++ [
          ./oggenc-input-detection.patch
          ./ogg123-speex-stats.patch
        ];
        postPatch = (o.postPatch or "") + ''
          for f in ogg123/ogg123.c oggdec/oggdec.c oggenc/oggenc.c \
                   ogginfo/ogginfo2.c vcut/vcut.c vorbiscomment/vcomment.c; do
            substituteInPlace "$f" --replace-fail \
              'setlocale(LC_ALL, "");' 'setlocale(LC_ALL, ""); setlocale(LC_NUMERIC, "C");'
          done
        '';
      };

      # ogg123 plays Ogg Opus when configure finds opusfile, which nixpkgs'
      # recipe doesn't pass. ogg123 reads files and streams through its own
      # transports, so opusfile's HTTP client (and openssl with it) is left out.
      opusfileFor = ps: ps.opusfile.overrideAttrs (o: {
        configureFlags = (o.configureFlags or [ ]) ++ [ "--disable-http" ];
        buildInputs = builtins.filter (d: (d.pname or "") != "openssl") (o.buildInputs or [ ]);
        meta = (o.meta or { }) // { platforms = ps.lib.platforms.all; broken = false; };
      });

      # A `--version` smoke passes a binary that cannot play or encode, so the
      # native build exercises every tool: Vorbis encode/decode through files
      # and pipes, ogg123 against oggdec, ReplayGain, lossless FLAC and Ogg FLAC
      # in both ogg123 and oggenc, Speex and Opus playback, comments, vcut, number
      # parsing in a decimal-comma locale, and on Linux ALSA's null PCM from
      # the built-in configuration. Runs wherever the build machine can execute
      # the result.
      roundTripCheck = pkgs: {
        doInstallCheck = pkgs.stdenv.buildPlatform.canExecute pkgs.stdenv.hostPlatform;
        nativeInstallCheckInputs = with pkgs.buildPackages; [ flac opus-tools ];
        # 0.2 s of Speex (nixpkgs' speex has no encoder), from
        # `speexenc --rate 8000 --quality 0`. The glibc ogg123 crashes on it.
        speexProbe = "T2dnUwACAAAAAAAAAABJBu0DAAAAADj/TOUBUFNwZWV4ICAgMS4yLjEAAAAAAAAAAAAAAAAAAAABAAAAUAAAAEAfAAAAAAAABAAAAAEAAAD/////oAAAAAAAAAABAAAAAAAAAAAAAAAAAAAAT2dnUwAAAAAAAAAAAABJBu0DAQAAAKKcJh4BJxgAAABFbmNvZGVkIHdpdGggU3BlZXggMS4yLjEBAAAAAwAAAFg9MU9nZ1MABEAGAAAAAAAASQbtAwIAAADj57exCwYGBgYGBgYGBgYGCFSIBuwPCFSIB2gPCFSJc2gPCFSJc2gPCFSJc2gPCFSJc2gPCFSJc2gPCFSJc2gPCFSJc2gPCFSJc2gPCESJrrQP";
        installCheckPhase = ''
          runHook preInstallCheck
          b=$out/bin
          fail() { echo "installCheck: $*"; exit 1; }
          LC_ALL=C awk 'BEGIN {
            for (i = 0; i < 44100; i++) {
              l = int(12000 * sin(6.283185307179586 * 440 * i / 44100)); if (l < 0) l += 65536
              r = int(12000 * sin(6.283185307179586 * 660 * i / 44100)); if (r < 0) r += 65536
              printf "%c%c%c%c", l % 256, int(l / 256), r % 256, int(r / 256)
            }
          }' > src.raw
          test "$(wc -c < src.raw)" -eq 176400 || fail "probe input has the wrong size"
          raw="-r -R 44100 -C 2 -B 16"

          "$b/oggenc" -Q -s 1 $raw src.raw -o a.ogg || fail "oggenc cannot encode"
          "$b/oggenc" -Q -s 1 $raw - -o - < src.raw > piped.ogg || fail "oggenc cannot encode through a pipe"
          cmp -s a.ogg piped.ogg || fail "oggenc through stdin/stdout differs from files"
          "$b/oggdec" -Q -R a.ogg -o a.raw || fail "oggdec cannot decode"
          test "$(wc -c < a.raw)" -eq 176400 || fail "oggdec did not decode 1 s"
          "$b/oggdec" -Q -R -o - - < a.ogg | cmp -s a.raw - || fail "oggdec through stdin/stdout differs from files"
          "$b/ogg123" -q -d raw -f play.raw a.ogg || fail "ogg123 cannot play Vorbis"
          cmp -s a.raw play.raw || fail "ogg123 and oggdec decode differently"
          "$b/vorbiscomment" -w -t 'REPLAYGAIN_TRACK_GAIN=-6.00 dB' a.ogg gain.ogg
          "$b/ogg123" -q -d raw -f gain.raw gain.ogg || fail "ogg123 cannot play a ReplayGain-tagged file"
          if cmp -s play.raw gain.raw; then fail "ogg123 ignores ReplayGain"; fi

          flacraw="--force-raw-format --endian=little --sign=signed --channels=2 --bps=16 --sample-rate=44100"
          flac --silent $flacraw src.raw -o src.flac
          flac --silent --ogg $flacraw src.raw -o src.oga
          for f in src.flac src.oga; do
            "$b/ogg123" -q -d raw -f back.raw "$f" || fail "ogg123 cannot play $f"
            cmp -s src.raw back.raw || fail "ogg123 changed the audio of $f"
            "$b/oggenc" -Q -s 1 "$f" -o flac.ogg || fail "oggenc cannot read $f"
            "$b/oggdec" -Q -R flac.ogg -o flac.raw
            cmp -s a.raw flac.raw || fail "oggenc read different audio from $f"
          done
          printf 'not audio\n' > junk.txt
          rc=0; "$b/oggenc" -Q junk.txt -o junk.ogg 2> /dev/null || rc=$?
          test "$rc" -eq 1 || fail "oggenc exits $rc on an unsupported input"

          printf %s "$speexProbe" | base64 -d > s.spx
          "$b/ogg123" -q -d raw -f speex.raw s.spx || fail "ogg123 cannot play Speex"
          test "$(wc -c < speex.raw)" -ge 3200 || fail "ogg123 played too little Speex"
          opusenc --quiet --raw --raw-rate 44100 --raw-chan 2 src.raw o.opus
          "$b/ogg123" -q -d raw -f opus.raw o.opus || fail "ogg123 cannot play Opus"
          test "$(wc -c < opus.raw)" -gt 150000 || fail "ogg123 played too little Opus"

          "$b/vorbiscomment" -R -w -t 'TITLE=Ação' a.ogg tagged.ogg || fail "vorbiscomment cannot write"
          "$b/vorbiscomment" -R -l tagged.ogg | grep -qx 'TITLE=Ação' || fail "comment did not round trip"
          "$b/vorbiscomment" -R -l - < tagged.ogg | grep -qx 'TITLE=Ação' || fail "vorbiscomment cannot read stdin"

          # Where the locale exists (macOS), a decimal comma must not change
          # how the options are read.
          export LC_ALL=pt_BR.UTF-8
          "$b/vcut" a.ogg c1.ogg c2.ogg +0.5 > /dev/null || fail "vcut failed"
          "$b/oggdec" -Q -R c1.ogg -o c1.raw
          test "$(wc -c < c1.raw)" -eq 88200 || fail "vcut +0.5 did not cut at half a second"
          "$b/oggenc" -Q -s 1 -q 4.5 $raw src.raw -o q45.ogg
          "$b/oggenc" -Q -s 1 -q 4 $raw src.raw -o q4.ogg
          if cmp -s q45.ogg q4.ogg; then fail "oggenc read -q 4.5 as 4"; fi
          "$b/ogginfo" a.ogg | grep -q 'Playback length: 0m:01.000s' || fail "ogginfo misreports the length"
          unset LC_ALL
        '' + pkgs.lib.optionalString pkgs.stdenv.hostPlatform.isLinux ''
          # The sandbox has alsa-lib's share/alsa in the store, so opening a PCM
          # alone can't tell the built-in configuration from a store path only
          # the build machine has; the grep closes that gap.
          if grep -aq share/alsa "$b/ogg123"; then fail "ALSA reads its configuration from disk"; fi
          "$b/ogg123" -q -d alsa -o dev:null a.ogg || fail "ALSA cannot open the null PCM from its built-in configuration"
        '' + ''
          echo "installCheck: encode, decode, playback, comments and vcut OK"
          runHook postInstallCheck
        '';
      };
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "vorbis-tools";
      smoke = [ "--unpin-program=ogg123" "--version" ];
      smokePattern = "ogg123.*vorbis-tools";

      # Build via the unpin-llvm engine + emit a bitcode multicall module: the
      # engine compiles vorbis-tools to bitcode and the standalone self-folds the
      # six CLIs into one `vorbis-tools` binary on every target, windows
      # included. Pure C — no requires.cxx.
      engine = "unpin-llvm";
      multicall = {
        windows = true;
        programs = [
          { name = "ogg123"; }
          { name = "oggenc"; }
          { name = "oggdec"; }
          { name = "ogginfo"; }
          { name = "vcut"; }
          { name = "vorbiscomment"; }
        ];
        # Plugin and data directories baked into the static libraries — libao's
        # and alsa-lib's dynamic-plugin dirs, pulseaudio's helper and locale dirs,
        # libpsl's list file. The binary loads no plugins (audio.nix compiles the
        # drivers in) and libpsl uses its built-in list, so these store paths are
        # never opened; scrub them so the binary carries no store reference. (It
        # has to be here: the top-level `removeReferences` does not reach an
        # engine multicall's binary.)
        removeReferences = [
          "libpulseaudio"
          "libao"
          "alsa-lib"
          "publicsuffix-list"
        ];
        # ogg123's pulse backend pulls libpulse's internal libpulsecommon, which
        # ships in lib/pulseaudio/ (not lib/) and so escapes the auto dep glob.
        # Linux only — the darwin libao drives CoreAudio, so audio.nix builds no
        # libpulse there and exposes no such passthru.
        depArchives = pkgs:
          pkgs.lib.optional pkgs.stdenv.hostPlatform.isLinux
            (pulseCommonArchive (withCodecFixes pkgs.pkgsStatic));
        # darwin: the self-fold relinks from the captured link inputs, but the
        # capture records only `-l`/`-L`, not `-framework` — so the frameworks
        # audio.nix puts in ao.pc's Libs.private (libao's macosx driver:
        # AudioComponent*/AudioOutputUnit*) and curl's proxy lookup
        # (SCDynamicStoreCopyProxies) must be named here too. darwin-only in
        # effect (the fold gates `-framework` on isDarwinHost).
        requires.frameworks = [
          "AudioUnit"
          "CoreAudio"
          "CoreServices"
          "SystemConfiguration"
        ];
      };

      # Native (Linux + Darwin). audio.nix returns a libao with the platform's
      # backends compiled in as built-in static drivers. speex gets the nix-lib
      # arm64-darwin meson fix (inert no-op elsewhere; same class as libopus).
      #
      # configure.ac probes for socket() in the legacy Solaris/BeOS link libs:
      #   AC_CHECK_LIB(socket, ...) / AC_CHECK_LIB(network, socket, -lnetwork).
      # On macOS socket() lives in libSystem (no extra lib needed), but
      # /usr/lib/libnetwork.dylib happens to exist and re-export socket, so the
      # `network` probe spuriously succeeds and sets SOCKET_LIBS=-lnetwork. That
      # -lnetwork ends up in ogg123's link line (and thus the merged binary),
      # adding a direct load of /usr/lib/libnetwork.dylib — a dyld-shared-cache
      # lib with no static archive, which trips action-build's darwin allow-list
      # (libSystem + /System/Library/Frameworks + libobjc). Pre-seed the autoconf
      # cache so the probe reports "no" on darwin; socket() still resolves from
      # libSystem. (Inert on Linux, where libnetwork doesn't exist anyway. curl
      # stays — it links static here, so http:// playback works on Linux + macOS.)
      build = pkgs:
        let
          ps = withCodecFixes pkgs.pkgsStatic;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          audioLibao = import ./audio.nix { lib = pkgs.lib // ulib; } ps;
          vorbisTools = ((ps.vorbis-tools.override {
            libao = audioLibao;
            speex = ulib.nativeFixes.speex ps;
          }).overrideAttrs sourceFixes).overrideAttrs (o: {
            configureFlags = (o.configureFlags or [ ]) ++ [
              "--disable-nls"
              # ogg123 reads system-wide settings from $sysconfdir/ogg123rc, which
              # would otherwise be a store path no user machine has.
              "--sysconfdir=/etc"
            ] ++ pkgs.lib.optional isDarwin "ac_cv_lib_network_socket=no";
            buildInputs = (o.buildInputs or [ ]) ++ [ (opusfileFor ps) ];
            doCheck = false;
          } // roundTripCheck pkgs);
        in
        vorbisTools;                           # engine path: apps → bitcode → selfFold

      # Windows via mingw. libao's WMM driver is already in static_drivers[] and
      # mingw has no dlopen, so vanilla cross libao gives playback for free — only
      # its meta.platforms=unix guard needs lifting. The codec libs cross cleanly;
      # lift their unix guard too. No pulse/alsa (those are Linux device APIs).
      #
      # curl is dropped on Windows: it's an OPTIONAL ogg123 dep (HTTP streaming),
      # configure auto-disables it when libcurl is absent (PKG_CHECK_MODULES →
      # HAVE_CURL=no), and its nixpkgs mingw cross is broken at the nghttp3 (HTTP/3)
      # examples. Local-file playback — the point of the Windows build — needs no
      # network stack, so the .exe stays self-contained without it.
      windowsBuild = pkgs:
        let
          cross = ulib.mingwStaticCross pkgs;
          metaAllow = d: d.overrideAttrs (o: {
            meta = (o.meta or { }) // { platforms = pkgs.lib.platforms.all; broken = false; };
          });
          # libao's WMM driver needs the Windows audio system libs at consumer
          # link time: -lwinmm (waveOut*) and -lksuser (the KSDATAFORMAT_SUBTYPE_*
          # GUIDs ksmedia.h declares extern). libao only records -lwinmm in
          # WMM_LIBS, so add both to ao.pc's Libs — that is what lets ogg123's own
          # link (`pkg-config --libs ao`) succeed, which is where the engine
          # captures its objects. The FINAL fold link does not inherit them: the
          # capture shim only resolves `-l<name>` that it can find as a
          # `lib<name>.a` under an explicit `-L` dir, and these are mingw sysroot
          # import stubs. They come from nix-lib's winExtraLibs force-link, the
          # same channel BCryptGenRandom and PathRemoveFileSpecA use.
          #
          # libao also opens the file devices (`ogg123 -d wav -f out.wav`) with
          # fopen "w", and writes `-f -` to stdout, both in text mode on Windows:
          # every 0x0A byte of the audio gained a 0x0D. Open them in binary mode.
          winLibao = (metaAllow cross.libao).overrideAttrs (o: {
            postPatch = (o.postPatch or "") + ''
              substituteInPlace ao.pc.in \
                --replace-fail "Libs: -L\''${libdir} -lao" "Libs: -L\''${libdir} -lao -lwinmm -lksuser"
              substituteInPlace src/audio_out.c \
                --replace-fail '#include <stdlib.h>' '#include <stdlib.h>
              #include <fcntl.h>
              #include <io.h>' \
                --replace-fail 'file = stdout;' '{ _setmode(_fileno(stdout), _O_BINARY); file = stdout; }' \
                --replace-fail 'file = fopen(filename, "w");' 'file = fopen(filename, "wb");'
            '';
          });
          vorbisTools = ((cross.vorbis-tools.override { libao = winLibao; }).overrideAttrs sourceFixes).overrideAttrs (o: {
            # --with-curl=no makes the AM_PATH_CURL fallback skip detection (it
            # otherwise finds a stray curl-config on PATH and sets HAVE_CURL=yes,
            # pulling http_transport.c which needs curl/curl.h we don't ship here).
            configureFlags = (o.configureFlags or [ ]) ++ [ "--disable-nls" "--with-curl=no" ];
            meta = (o.meta or { }) // { platforms = pkgs.lib.platforms.all; broken = false; };
            # ogg123's pthread prebuffer (buffer.c) pulls <sys/wait.h> (absent on
            # mingw) and masks SIGTSTP/SIGCONT (no such signals on Windows). The
            # patch guards both under #ifndef _WIN32 — the buffer thread just runs
            # unmasked, which is correct on Windows.
            # ogg123 also uses Unix job-control (SIGTSTP/SIGCONT/SIGSTOP + kill,
            # for terminal pause/resume) and random()/srandom(); none exist on
            # Windows. The signals patch guards the job-control under #ifndef _WIN32
            # and maps random→rand. Playback (WMM) and everything else is intact.
            #
            # Upstream never ran ogg123 on Windows, and the tools open binary
            # streams in text mode there: ogg123 opened every file with fopen "r"
            # (so it could play no Vorbis or FLAC file at all), and ogg123,
            # vorbiscomment and vcut read `-` from stdin (and write `-` to
            # stdout) untranslated. oggdec also took a pipe for a seekable file,
            # because msvcrt's fseek succeeds on one, and hung on `type x | oggdec -`.
            patches = (o.patches or [ ]) ++ [
              ./mingw-ogg123-buffer.patch
              ./mingw-ogg123-signals.patch
              ./mingw-ogg123-status.patch
              ./mingw-binary-io.patch
            ];
            # ogg123's buffer.c is pthread-based; mingw provides POSIX threads via
            # winpthreads (windows.pthreads), which isn't a default buildInput.
            buildInputs = builtins.map metaAllow
              (builtins.filter (d: (d.pname or "") != "curl") (o.buildInputs or [ ]))
              ++ [ cross.windows.pthreads (opusfileFor cross) ];
            # FLAC's headers decorate the public API with __declspec(dllimport) on
            # _WIN32 unless FLAC__NO_DLL is defined; against the static libFLAC.a
            # the consumer otherwise sees __imp_FLAC__* undefined. (Static dllimport
            # pattern — here the macro lives in CFLAGS since we link static.)
            env = (o.env or { }) // {
              # -DFLAC__NO_DLL: static libFLAC (see above).
              # -DNAME_MAX=255: playlist.c uses the POSIX limits.h constant for the
              # max filename length; mingw doesn't define it (255 is the usual value).
              NIX_CFLAGS_COMPILE = (o.env.NIX_CFLAGS_COMPILE or "") + " -DFLAC__NO_DLL -DNAME_MAX=255";
            };
            # share/utf8.c splits into a _WIN32 branch (direct Windows Unicode
            # APIs) and a #else branch for "real operating systems". convert_*()
            # charset state only exists in the #else branch, but all six tools
            # call convert_free_charset() unconditionally → undefined on mingw.
            # The win32 path has no charset state, so a no-op stub is correct.
            postPatch = (o.postPatch or "") + ''
              substituteInPlace share/utf8.c \
                --replace-fail \
                  "#else /* End win32. Rest is for real operating systems */" \
                  "void convert_free_charset(void) { }
              #else /* End win32. Rest is for real operating systems */"
              # ogg123 remote.c uses the BSD setlinebuf(); mingw has only the
              # standard setvbuf line-buffering it's shorthand for.
              substituteInPlace ogg123/remote.c \
                --replace-fail "setlinebuf(stdout);" "setvbuf(stdout, NULL, _IOLBF, 0);"
              # ogg123's system-wide settings file is $sysconfdir/ogg123rc, a
              # Unix location with no Windows counterpart (here it was a store
              # path), so the Windows build reads only the user's own file.
              substituteInPlace ogg123/cfgfile_options.c \
                --replace-fail 'parse_config_file(opts, SYSCONFDIR "/ogg123rc");' '#ifndef _WIN32
                parse_config_file(opts, SYSCONFDIR "/ogg123rc");
              #endif'
            '';
          });
        in
        vorbisTools;
    };
}
