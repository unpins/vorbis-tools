{
  description = "vorbis-tools (ogg123 player + Ogg Vorbis utilities) as a single self-contained binary";

  nixConfig = {
    extra-substituters = [ "https://unpins.cachix.org" ];
    extra-trusted-public-keys = [ "unpins.cachix.org-1:DDaShjbZ8VvcqxeTcAU3kV9vxZQBlyb7V/uLBHfTynI=" ];
  };

  inputs.unpins-lib.url = "github:unpins/nix-lib";

  # vorbis-tools installs six CLIs — ogg123 (play), oggenc (encode), oggdec
  # (decode), ogginfo (inspect), vcut (split) and vorbiscomment (tag);
  # ./multicall.nix post-links them into one `vorbis-tools` dispatcher binary
  # with each tool as an argv[0]-dispatch UNPIN_META alias. The canonical binary
  # is named `vorbis-tools` (the package name) to match unpins/action-build's
  # result/bin/<package_name> contract; the bare dispatcher falls through to the
  # flagship player ogg123, so `vorbis-tools --version` prints ogg123's banner.
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
    in
    ulib.mkStandaloneFlake {
      inherit self;
      name = "vorbis-tools";
      smoke = [ "--version" ];
      smokePattern = "ogg123.*vorbis-tools";

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
          ps = pkgs.pkgsStatic;
          isDarwin = pkgs.stdenv.hostPlatform.isDarwin;
          audioLibao = import ./audio.nix { lib = pkgs.lib // ulib; } ps;
          vorbisTools = (ps.vorbis-tools.override {
            libao = audioLibao;
            speex = ulib.nativeFixes.speex ps;
          }).overrideAttrs (o: {
            configureFlags = (o.configureFlags or [ ]) ++ [ "--disable-nls" ]
              ++ pkgs.lib.optional isDarwin "ac_cv_lib_network_socket=no";
          });
        in
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs vorbisTools; };

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
          # WMM_LIBS, so add both to ao.pc's Libs (ogg123 links `pkg-config --libs
          # ao`; the multicall then re-harvests them from that link line).
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
        import ./multicall.nix { lib = pkgs.lib // ulib; }
          { inherit pkgs vorbisTools; };
    };
}
