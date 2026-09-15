# vorbis-tools

The [vorbis-tools](https://xiph.org/vorbis/) command-line programs — play, encode, decode and tag [Ogg Vorbis](https://xiph.org/vorbis/) audio, including the `ogg123` player. A single self-contained binary, built natively for Linux, macOS, and Windows.

[![CI](https://github.com/unpins/vorbis-tools/actions/workflows/vorbis-tools.yml/badge.svg)](https://github.com/unpins/vorbis-tools/actions)
![Linux](https://img.shields.io/badge/Linux-✓-success?logo=linux&logoColor=white)
![macOS](https://img.shields.io/badge/macOS-✓-success?logo=apple&logoColor=white)
![Windows](https://img.shields.io/badge/Windows-✓-success?logo=windows&logoColor=white)

Part of the [unpins](https://unpins.org) catalog; install it with [`unpin`](https://github.com/unpins/unpin): `unpin install vorbis-tools`.

## Usage

Run a program with [unpin](https://github.com/unpins/unpin):

```bash
unpin vorbis-tools --unpin-program=ogg123 song.ogg
unpin vorbis-tools --unpin-program=oggenc -q 6 song.wav
```

Or install them and call each by name, which is usually what you want:

```bash
unpin install vorbis-tools
ogg123 song.ogg
```

`unpin install vorbis-tools` creates the `ogg123`, `oggenc`, `oggdec`, `ogginfo`, `vcut` and `vorbiscomment` commands.

## Programs

| command         | what it does                                              |
| --------------- | --------------------------------------------------------- |
| `ogg123`        | play Ogg Vorbis, Opus, Speex, FLAC and Ogg FLAC files     |
| `oggenc`        | encode WAV / AIFF / FLAC / Ogg FLAC / raw PCM to Vorbis   |
| `oggdec`        | decode Vorbis back to WAV or raw PCM                      |
| `ogginfo`       | show stream information for an Ogg file                   |
| `vcut`          | split a Vorbis file in two at a sample or a time          |
| `vorbiscomment` | list or edit the tags of a Vorbis file                    |

`ogg123` plays through the system's sound output — PulseAudio or PipeWire
(falling back to ALSA, then OSS) on Linux, CoreAudio on macOS, and the
Windows audio system on Windows. It also writes to a file instead, as in
`ogg123 -d wav -f out.wav song.ogg`.

## Man pages

The six man pages are embedded in the binary — read one with
`unpin man vorbis-tools ogg123`.

## Build locally

```bash
nix build github:unpins/vorbis-tools
./result/bin/vorbis-tools --unpin-program=ogg123 --version
```

Or run directly:

```bash
nix run github:unpins/vorbis-tools -- --unpin-program=ogg123 --version
```

The first invocation will offer to add the [unpins.cachix.org](https://unpins.cachix.org) substituter so most pulls come pre-built.

## Manual download

The [Releases](https://github.com/unpins/vorbis-tools/releases) page has standalone binaries for manual download.

## Build notes

- **Sound output needs no libraries on the system.** The Linux binary talks to
  PulseAudio or PipeWire directly and carries ALSA's configuration, so it also
  plays on systems without ALSA's files; `/etc/asound.conf` and `~/.asoundrc`
  still apply.
- **Windows:** a single `.exe`, no companion DLLs. `ogg123` never supported
  Windows upstream and is ported here; it plays local files and standard input
  but not `http://` streams, which need a network library the Windows build
  leaves out. Linux and macOS play `http://` and `https://` streams.
- **Numbers in options always use a dot** (`oggenc -q 4.5`, `vcut in.ogg a.ogg b.ogg +2.5`),
  whatever the system's locale. Upstream reads them with the locale's decimal
  separator, so where that is a comma `-q 4.5` silently became quality 4.
- `ogg123` reads its settings from `/etc/ogg123rc` and `~/.ogg123rc` on Linux
  and macOS.
