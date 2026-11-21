# Image Pipeline

How photographs become the images the model reads. Covers R3.1, R8.2, R8.3.

## Path

```
LrPhoto (selected)
   │
   │  LrExportSession{ photosToExport, exportSettings }  →  session:renditions()
   ▼
temp JPEGs  (<temp>/genreator-<runId>/…)   ← current develop settings applied, upright
   │
   │  rendition:waitForRender()  →  (success, path)
   ▼
request.json (paths + Personal flags)  →  model/localgenres  →  response.json
   │
   ▼
delete the chunk's JPEGs
```

The original RAW is never read by the model. What it sees is what Lightroom would export —
the photograph's current developed appearance (R3.1), upright, so the request always says
orientation `AB`.

## Export settings

```lua
{
  LR_format                       = 'JPEG',
  LR_jpeg_quality                 = 0.8,         -- 0..1 in the SDK, not 0..100
  LR_export_colorSpace            = 'sRGB',

  LR_size_doConstrain             = true,
  LR_size_resizeType              = 'longEdge',
  LR_size_maxWidth                = 1024,        -- config: renditionLongEdge
  LR_size_maxHeight               = 1024,
  LR_size_units                   = 'pixels',
  LR_size_doNotEnlarge            = true,

  LR_export_destinationType       = 'specificFolder',
  LR_export_destinationPathPrefix = <per-run temp dir>,
  LR_export_useSubfolder          = false,
  LR_collisionHandling            = 'rename',

  LR_embeddedMetadataOption       = 'copyrightOnly', -- strip EXIF/IPTC/XMP except copyright
  LR_removeFaceMetadata           = true,        -- face regions carry people's names
  LR_removeLocationMetadata       = true,        -- strip GPS           (R8.3)
  LR_metadata_keywordOptions      = 'flat',

  LR_outputSharpeningOn           = false,
  LR_useWatermark                 = false,
  LR_reimportExportedPhoto        = false,       -- must stay false
}
```

Three settings carry real weight:

- **`LR_removeLocationMetadata = true`** — no keyword text reaches the model (ADR-013); this setting governs the *file*. Without it, GPS coordinates ride along inside the JPEG.
- **`LR_reimportExportedPhoto = false`** — true would add the temporary renditions to the catalog. Non-negotiable.
- **`LR_embeddedMetadataOption = 'copyrightOnly'`** — the legacy `LR_minimizeEmbeddedMetadata` is silently ignored by current Lightroom: a rendition built with it still carried camera/lens serials, the raw filename and every develop setting. An unknown export-setting key produces no error, so only inspecting real output (`exiftool` on a rendition taken from the run's temp folder) proves a privacy setting works.

`LR_size_doNotEnlarge` means small originals are rendered at native size rather than
upscaled into meaningless pixels. `LR_collisionHandling = 'rename'`: two photographs of a
chunk with the same file name each get their own file, which must exist until the model has
read it.

## Resolution and quality

**Default: 1024 px long edge, JPEG quality 0.8.**

The model's image encoder reads every photograph at 256 × 256 px, and it was trained on
Lightroom previews of about 1,000 px or more. 1024 px therefore matches training; a larger
rendition only costs time, a much smaller one changes what the encoder sees from what it was
trained on. Both are config values (`renditionLongEdge`, `jpegQuality`); change them only with
a reason.

## Temp file lifecycle

1. Per-run directory: `LrPathUtils.child(LrPathUtils.getStandardFilePath('temp'), 'genreator-' .. runId)`.
2. Each chunk's renditions are deleted **right after the model call that reads them**, whether
   it succeeded or failed. Peak disk footprint is one chunk of JPEGs.
3. The request and response files live in the same directory and go with it.
4. The directory is removed in an `LrFunctionContext:addCleanupHandler`, so it runs on
   success, error and user cancellation alike; leftovers of a crashed run are swept at the
   start of the next.

```lua
context:addCleanupHandler(function()
  Rendition.removeTempDir(tempDir)
end)
```

## Batching

Renditions are produced in chunks (`chunkSize`, default 50), one `LrExportSession` per chunk,
and each chunk is one model call. The model loads its encoder once per call (about 2 s), then
takes about 10 ms per photograph, so larger chunks are faster; smaller chunks write results to
the catalog sooner and keep less on disk.

## Skipped photographs

- **Video** — `photo:getRawMetadata('fileFormat') == 'VIDEO'`. Skipped; genre does not apply.
- **Offline originals** — `not photo:checkPhotoAvailability()` (a method that needs a task; there is no `isMissing` raw-metadata key). If the photo has a **Smart Preview** (`getRawMetadata('smartPreviewInfo')`, ~2560 px), Lightroom exports from it and the photo is classified; only "no original and no Smart Preview" is skipped, with advice to reconnect the drive or build Smart Previews. `smartPreviewInfo` is guarded: if Lightroom rejects the key, offline photos are attempted, so a failure is a visible per-photo error rather than a silent skip.
- **Already classified** — skipped unless reclassifying (R6.5).

**Virtual copies are treated as distinct photographs**, correctly: they have their own
develop settings, so a black-and-white virtual copy can legitimately read as a different
genre from its colour parent.
