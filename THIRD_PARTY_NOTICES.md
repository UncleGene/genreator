# Third-party notices

Genreator is MIT-licensed ([`LICENSE`](LICENSE)); that covers the plugin code, the genre model
(`Genreator.lrplugin/model/model.json`), its runtime (`Genreator.lrplugin/model/localgenres`)
and the genre definitions. The runtime is distributed as a prebuilt program (macOS, Apple
silicon); its source is not published. One component has its own licence.

## Image encoder — SigLIP2 base patch16/256

- **What:** the image tower of SigLIP2 base patch16/256 by Google, which turns a photograph
  into 768 numbers that the genre model reads.
- **Licence:** Apache License, Version 2.0 — [`licenses/Apache-2.0.txt`](licenses/Apache-2.0.txt).
  The upstream release has no NOTICE file.
- **Source:** <https://huggingface.co/google/siglip2-base-patch16-256>
- **Changes:** converted to Core ML and compiled; only the image tower is included. The
  weights were not retrained.
- **Where:** `Genreator.lrplugin/model/encoders/`, with the licence text (`LICENSE`) and the
  statement of changes (`NOTICE`) beside it: inside the plugin release zip, or downloaded by
  `make install` in a development install.

Google is named for attribution only; it does not endorse Genreator.
