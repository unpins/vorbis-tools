# vorbis-tools

Standalone build of the [vorbis-tools](https://xiph.org/vorbis/) command-line
utilities — play, encode, decode and tag [Ogg Vorbis](https://xiph.org/vorbis/)
audio, including the `ogg123` player.

[![CI](https://github.com/unpins/vorbis-tools/actions/workflows/vorbis-tools.yml/badge.svg)](https://github.com/unpins/vorbis-tools/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) project — native single-binary builds with no third-party runtime dependencies.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin vorbis-tools ogg123 song.ogg
unpin vorbis-tools oggenc song.wav
```

To install the programs onto your PATH:

```bash
unpin install vorbis-tools
```

`unpin install vorbis-tools` also creates the `ogg123`, `oggenc`, `oggdec`, `ogginfo`, `vorbiscomment`, `vcut` commands.

## Programs

One binary provides all six vorbis-tools CLIs:

| command         | what it does                                              |
| --------------- | -------------------------------------------------------- |
| `ogg123`        | play Ogg Vorbis / FLAC / Speex to the sound device       |
| `oggenc`        | encode WAV / AIFF / FLAC / raw PCM to Ogg Vorbis          |
| `oggdec`        | decode Ogg Vorbis to WAV / raw PCM                        |
| `ogginfo`       | show stream, header and tag info for an Ogg file          |
| `vorbiscomment` | read and edit Ogg Vorbis comment tags                     |
| `vcut`          | split an Ogg Vorbis file at a cutpoint or time            |

`ogg123` plays through the OS sound system out of the box — PulseAudio/PipeWire
(falling back to ALSA, then OSS) on Linux, CoreAudio on macOS, WMM on Windows —
with no shared libraries alongside the binary.

## Build locally

```bash
nix build github:unpins/vorbis-tools
./result/bin/ogg123 --version
```

Or run directly:

```bash
nix run github:unpins/vorbis-tools -- --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/vorbis-tools/releases) page has standalone binaries for manual download.

## Build notes

- One multicall binary holds all six tools. `vorbis-tools` is the canonical name
  (a busybox-style dispatcher); the six tool names dispatch on `argv[0]`. They
  share the heavy static archives — libvorbis / libogg / libFLAC / libspeex and,
  for `ogg123`, libao — linked once.
- Live audio is fully static: libao's backends, normally dlopen-loaded plugins,
  are compiled directly into the binary as built-in drivers (pulse + alsa + oss
  on Linux, CoreAudio on macOS, WMM on Windows). `ogg123` talks straight to the
  PulseAudio/PipeWire socket — no daemon library on disk.
- The tools are folded together post-link by renaming each tool's `main` (and
  its other globals) with `objcopy`, then linking the renamed objects against the
  shared archives read from each tool's real link command.
- **Windows** is built with mingw and carries no companion DLLs. `ogg123` (which
  upstream never ported to Windows) is ported here for WMM playback; its
  HTTP-streaming transport is left out (local playback needs no network stack).
- All six upstream man pages are embedded in the binary.
```
