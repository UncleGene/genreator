# Privacy, Security and Failure Handling

Photographs may be private. This document states exactly what the plugin reads, writes and
keeps.

## Nothing leaves the computer

Classification runs on the bundled model, on the Mac (ADR-021). The plugin makes **no network
connection**: no upload, no telemetry, no account. The only download is the plugin itself, a
release zip with the image encoder inside (ADR-026); a development install fetches the encoder
once with `make install` and checks it against the committed checksums.

**What the model receives, per photograph:** a rendered JPEG (1024 px long edge, quality 0.8,
sRGB, **GPS stripped, embedded metadata limited to copyright, face regions stripped**) and
one true/false flag — whether the photograph carries the Personal keyword or a keyword under
it (ADR-024). Nothing else: no keyword text, folder, date, caption, rating, location or EXIF
field (ADR-013). The rendition keeps the original's file name, so its path in the local
request file shows it.

**What the plugin reads from keywords:** only whether a keyword sits in the Personal tree, and which
`Genre > X` keywords are present (the user's pre-tags, ADR-023). Person keywords and every
other keyword are not read for classification; their names are never copied anywhere. The keyword
commands (ADR-030) read which keywords at the keyword vocabulary's paths a photograph has, to
re-synchronise and record decisions; Suggest Keywords sends every photograph to the model as
not personal. A
keyword judgements file holds per-photograph data and stays where the user keeps it, never in
the bundle or the repository.

## Temporary files

- One directory per run under the OS temp path (`genreator-<runId>`).
- It holds the chunk's renditions, the request file (rendition paths and the Personal flag)
  and the model's response. The renditions are deleted **right after the model call that
  reads them**, successful or not; the directory goes in an `LrFunctionContext` cleanup
  handler, so on success, error and cancellation alike.
- Renditions are never written inside the catalog folder or the repository.
  `LR_reimportExportedPhoto = false` — renditions never enter the catalog.

Residue after a hard crash (SIGKILL, power loss) is possible; the OS temp directory is the
containment boundary. The next run removes stale `genreator-*` directories.

## The model runtime

`model/localgenres` is the one program the plugin launches (ADR-006, ADR-021). It is a prebuilt
program whose source is not published (README, *Licence*). The plugin launches it through
`GrCli`: by absolute path, every argument single-quoted, a fixed `PATH`, a hard timeout
(`modelTimeoutSeconds`), started in the run's own directory. Photograph data travels only in
the request file, never on the command line. The model's files are checked against SHA-256
checksums when packaged (`make release`), installed from the source (`make install`) or
imported (`make model`).

## Approved genres files

An approved genres file (ADR-025) holds per-photograph data from a catalog: UUIDs, file names
and genre decisions. The plugin reads it once, when you choose it; it never copies it. Keep
such files out of shared folders and repositories — the repository ignores `*labels*.json`.

## Configuration

An optional `~/.config/genreator/config.json` (ADR-008) holds tunables only — no keys or
secrets exist.

## Logging

Log file: `~/.config/genreator/logs/genreator.log`, rotated at 1 MB.

| Logged | Never logged |
|---|---|
| Timestamps, run ids, photo local ids | Image bytes |
| Genres, review states, counts | Request or response files |
| Model version, durations | File paths, filenames, captions, GPS |
| Error codes and messages | Keyword values |

`logLevel = "debug"` increases verbosity but **does not** unlock any of the right-hand column.

## Failure modes

| Failure | Behaviour |
|---|---|
| Config unparseable or a bad value | Abort before any work; name the file |
| Model files missing (plugin folder incomplete, or encoder not downloaded) | Abort before any work; *Check Model* names the file |
| Runtime blocked by macOS quarantine (a downloaded zip) | macOS shows *“localgenres” Not Opened* and the run waits until it is answered (or the model timeout, 10 minutes by default); then the model fails as a whole (below) and *Check Model* shows the `xattr` command with the plugin's path (ADR-026) |
| Rendition fails for one photo | Per-photo error; run continues |
| The model cannot read one photo | Per-photo error; run continues |
| The model fails as a whole (crash, timeout, wrong taxonomy, unreadable response) | Run stops; renditions deleted; the remaining photographs stay unclassified, not errors |
| User cancels | Rendering stops; the running model stops at the next photograph; temp directory removed; finished results kept |
| Lightroom quits mid-run | Completed chunks are written; classify the same selection again to continue |
| Catalog write fails | Surfaced; earlier chunks stay written |

Every error path leaves the catalog in a consistent state: a photograph is either
unclassified, suggested, decided, or explicitly `error`. A photograph that failed is
*visible* in the review collection rather than quietly absent.

## Reverting

- `Clear Plugin Data` — resets the selection's plugin metadata to `unclassified` (the genre
  fields and keywords stay).
- `Remove Genre Keywords` — removes the `Genre` keywords of the taxonomy and the genre fields
  from the selection.

Neither touches ratings, flags, labels, develop settings, or any keyword outside the
taxonomy (R5.6). Lightroom's own Undo covers writes made within the current session.
