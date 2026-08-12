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
          vorbisTools = (ps.vorbis-tools.override {
            libao = audioLibao;
            speex = ulib.nativeFixes.speex ps;
          }).overrideAttrs (o: {
            configureFlags = (o.configureFlags or [ ]) ++ [ "--disable-nls" ]
              ++ pkgs.lib.optional isDarwin "ac_cv_lib_network_socket=no";
            # The upstream installCheck runs a single tool we'd be replacing.
            doCheck = false;
            doInstallCheck = false;
          });
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
          winLibao = (metaAllow cross.libao).overrideAttrs (o: {
            postPatch = (o.postPatch or "") + ''
              substituteInPlace ao.pc.in \
                --replace-fail "Libs: -L\''${libdir} -lao" "Libs: -L\''${libdir} -lao -lwinmm -lksuser"
            '';
          });
          vorbisTools = (cross.vorbis-tools.override { libao = winLibao; }).overrideAttrs (o: {
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
            patches = (o.patches or [ ]) ++ [
              ./mingw-ogg123-buffer.patch
              ./mingw-ogg123-signals.patch
              ./mingw-ogg123-status.patch
            ];
            # ogg123's buffer.c is pthread-based; mingw provides POSIX threads via
            # winpthreads (windows.pthreads), which isn't a default buildInput.
            buildInputs = builtins.map metaAllow
              (builtins.filter (d: (d.pname or "") != "curl") (o.buildInputs or [ ]))
              ++ [ cross.windows.pthreads ];
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
            '';
          });
        in
        vorbisTools;
    };
}
