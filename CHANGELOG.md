# Changelog

## [Unreleased]

## [1.4.3-2] - 2026-09-26

### Fixed

- On Windows, `ogg123` could not play any Ogg Vorbis or FLAC file, from disk
  or from standard input (`Error opening … using the oggvorbis module`), so
  it played nothing but Speex. It read the files as text.

- On Windows, writing audio to a file or to standard output
  (`ogg123 -d wav -f out.wav`, `ogg123 -d raw -f -`) corrupted it, and
  `vorbiscomment` and `vcut` could not read an Ogg file from standard input
  or write one to standard output. `oggdec` hung when reading from a pipe, as
  in `type song.ogg | oggdec -o - -`.

- On Linux, `ogg123` could not play through ALSA — for example with
  `default_driver=alsa` in `/etc/libao.conf`, or `-d alsa` — and stopped with
  `Cannot access file …/alsa.conf`. The binary looked for the ALSA
  configuration in a directory that only existed on the build machine. That
  configuration is now built into the binary, so ALSA no longer needs any
  files from the system; `/etc/asound.conf` and `~/.asoundrc` still apply.

- `ogg123` ignored ReplayGain tags on every platform, so tagged files played
  at their unadjusted volume.

- On macOS and Windows, in a language whose decimal separator is a comma,
  numbers with a dot in options were cut at the dot, silently:
  `oggenc -q 4.5` encoded at quality 4 and `vcut in.ogg a.ogg b.ogg +0.5`
  cut at the start. Options now always take a dot.

- `oggenc` never accepted an Ogg FLAC file as input ("not a supported
  format"), and crashed on any input it did not recognize.

- Playing a Speex file made `ogg123` write past the end of a buffer, which
  can crash it.

- On Linux and macOS, `ogg123` now reads system-wide settings from
  `/etc/ogg123rc`.

### Added

- `ogg123` plays Ogg Opus files.
