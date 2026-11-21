--[[
GrRendition — render selected photos to temporary JPEG files for the model.

Uses LrExportSession rather than photo:requestJpegThumbnail (ADR-005): the export pipeline
gives exact dimensions, explicit JPEG quality, sRGB conversion, an upright image, and
LR_removeLocationMetadata, which strips GPS from the bytes themselves (R8.3).

The files live in the run's temp directory only until the model has read them: the
classifier deletes each chunk's files right after the model call, and the directory itself
on every exit path (R8.2).

Must be called from within an LrTasks task: waitForRender() yields.
]]

local LrExportSession = import 'LrExportSession'
local LrFileUtils     = import 'LrFileUtils'
local LrPathUtils     = import 'LrPathUtils'

local Log = require 'GrLog'

local Rendition = {}

--- Build the export settings table (docs/image-pipeline.md).
-- Pure, so the privacy-critical flags can be asserted in tests.
function Rendition.exportSettings(destFolder, cfg)
  local longEdge = (cfg and cfg.renditionLongEdge) or 1024
  local quality  = (cfg and cfg.jpegQuality) or 0.8

  return {
    LR_format                       = 'JPEG',
    LR_jpeg_quality                 = quality,          -- SDK uses 0..1, not 0..100
    LR_export_colorSpace            = 'sRGB',
    LR_jpeg_useLimitSize            = false,

    LR_size_doConstrain             = true,
    LR_size_resizeType              = 'longEdge',
    LR_size_maxWidth                = longEdge,
    LR_size_maxHeight               = longEdge,
    LR_size_units                   = 'pixels',
    LR_size_doNotEnlarge            = true,
    LR_size_resolution              = 72,
    LR_size_resolutionUnits         = 'inch',

    LR_export_destinationType       = 'specificFolder',
    LR_export_destinationPathPrefix = destFolder,
    LR_export_useSubfolder          = false,
    -- Two photographs of a chunk can share a file name; each needs its own file until the
    -- model has read it, so a collision gets a new name (the path is taken from the render).
    LR_collisionHandling            = 'rename',
    LR_extensionCase                = 'lowercase',

    -- Privacy: strip metadata from the uploaded bytes (R8.3).
    -- 'copyrightOnly' is the SDK's most restrictive option. LR_minimizeEmbeddedMetadata
    -- was silently ignored: M1 check 7 found camera and lens serials, the raw filename and
    -- all develop settings in the uploaded JPEG.
    LR_embeddedMetadataOption       = 'copyrightOnly',
    LR_removeFaceMetadata           = true,             -- region names are people's names
    LR_removeLocationMetadata       = true,
    LR_metadata_keywordOptions      = 'flat',

    LR_outputSharpeningOn           = false,
    LR_useWatermark                 = false,

    -- Must stay false: true would add renditions to the catalog.
    LR_reimportExportedPhoto        = false,
  }
end

--- Create the per-run temp directory.
-- @return path
function Rendition.createTempDir(runId)
  local base = LrPathUtils.getStandardFilePath('temp')
  local dir = LrPathUtils.child(base, 'genreator-' .. tostring(runId))
  if not LrFileUtils.exists(dir) then
    LrFileUtils.createAllDirectories(dir)
  end
  return dir
end

--- Remove a run's temp directory. Safe to call repeatedly.
function Rendition.removeTempDir(dir)
  if dir and LrFileUtils.exists(dir) then
    local ok, err = pcall(function() LrFileUtils.delete(dir) end)
    if not ok then
      Log.warnf('could not remove temp directory: %s', tostring(err))
    end
  end
end

--- Remove leftover temp directories from runs that died hard.
function Rendition.cleanStaleTempDirs(currentDir)
  local base = LrPathUtils.getStandardFilePath('temp')
  local ok = pcall(function()
    for entry in LrFileUtils.directoryEntries(base) do
      local leaf = LrPathUtils.leafName(entry)
      if leaf:match('^genreator%-') and entry ~= currentDir then
        pcall(function() LrFileUtils.delete(entry) end)
      end
    end
  end)
  if not ok then
    Log.debug('stale temp scan skipped')
  end
end

--- Delete one rendition file. Safe on a missing file.
function Rendition.deleteFile(path)
  pcall(function()
    if path and LrFileUtils.exists(path) then LrFileUtils.delete(path) end
  end)
end

--- Render a batch of photos to files in `destFolder`.
--
-- The callback receives (photo, path, info) for successes and (photo, nil, info) for
-- failures, where info.errorCode / info.errorMessage explain why. The caller deletes the
-- files (Rendition.deleteFile) once the model has read them.
--
-- @param photos array of LrPhoto
-- @param destFolder temp directory from createTempDir
-- @param cfg config table
-- @param callback function(photo, pathOrNil, info)
-- @param progress optional LrProgressScope; cancellation is checked between photos
-- @return number of photos processed
function Rendition.renderBatch(photos, destFolder, cfg, callback, progress)
  if #photos == 0 then return 0 end

  local session = LrExportSession {
    photosToExport = photos,
    exportSettings = Rendition.exportSettings(destFolder, cfg),
  }

  local processed = 0

  -- renditions() starts rendering itself; calling doExportOnNewTask() as well makes
  -- Lightroom refuse the second start. The iterator yields (index, rendition).
  for _, rendition in session:renditions() do
    if progress and progress:isCanceled() then
      Log.info('rendition loop cancelled by user')
      break
    end

    local photo = rendition.photo
    local success, pathOrMessage = rendition:waitForRender()
    local path = success and (pathOrMessage or rendition.destinationPath) or nil

    if not success then
      Log.warnf('rendition failed (code path only, no identifying detail logged)')
      callback(photo, nil, { errorCode = 'render_failed', errorMessage = tostring(pathOrMessage) })
    elseif not (path and LrFileUtils.exists(path)) then
      callback(photo, nil, { errorCode = 'render_unreadable', errorMessage = 'rendition file is missing' })
    else
      callback(photo, path, {})
    end

    processed = processed + 1
  end

  return processed
end

return Rendition
