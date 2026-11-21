--[[
Tests for GrRendition. The export settings are pure, and two of their flags carry the
privacy promise (R8.3), so they are asserted explicitly rather than trusted.
]]

local t = require 'harness'
local Rendition = require 'GrRendition'

t.suite('GrRendition — export settings')

local s = Rendition.exportSettings('/tmp/genreator-run', {
  renditionLongEdge = 1024,
  jpegQuality = 0.8,
})

t.eq(s.LR_format, 'JPEG', 'exports JPEG')
t.eq(s.LR_export_colorSpace, 'sRGB', 'converts to sRGB')
t.eq(s.LR_jpeg_quality, 0.8, 'quality is on the SDK 0..1 scale')
t.ok(s.LR_jpeg_quality <= 1, 'quality is never expressed on a 0..100 scale')

t.suite('GrRendition — privacy-critical flags (R8.3)')

t.eq(s.LR_removeLocationMetadata, true,
     'GPS is stripped from the rendition bytes — no keyword text is sent, this governs the file')
t.eq(s.LR_embeddedMetadataOption, 'copyrightOnly',
     'embedded metadata is limited to copyright — serials, filename, develop settings stripped')
t.eq(s.LR_removeFaceMetadata, true, 'face regions (people\'s names) are stripped')
t.isNil(s.LR_minimizeEmbeddedMetadata,
       'the ignored legacy key is gone, so it cannot be mistaken for protection')
t.eq(s.LR_reimportExportedPhoto, false,
     'renditions are never re-imported into the catalog')
t.eq(s.LR_useWatermark, false, 'no watermark')

t.suite('GrRendition — sizing')

t.eq(s.LR_size_doConstrain, true, 'size is constrained')
t.eq(s.LR_size_resizeType, 'longEdge', 'constrains the long edge')
t.eq(s.LR_size_maxWidth, 1024, 'max width matches config')
t.eq(s.LR_size_maxHeight, 1024, 'max height matches config')
t.eq(s.LR_size_units, 'pixels', 'sizes are in pixels')
t.eq(s.LR_size_doNotEnlarge, true,
     'small originals are not upscaled into meaningless pixels')

local small = Rendition.exportSettings('/tmp/x', { renditionLongEdge = 512, jpegQuality = 0.6 })
t.eq(small.LR_size_maxWidth, 512, 'long edge is configurable')
t.eq(small.LR_jpeg_quality, 0.6, 'quality is configurable')

local defaults = Rendition.exportSettings('/tmp/x', nil)
t.eq(defaults.LR_size_maxWidth, 1024, 'defaults to 1024 px with no config')
t.eq(defaults.LR_jpeg_quality, 0.8, 'defaults to 0.8 quality with no config')

t.suite('GrRendition — destination')

t.eq(s.LR_export_destinationType, 'specificFolder', 'exports to a specific folder')
t.eq(s.LR_export_destinationPathPrefix, '/tmp/genreator-run',
     'destination is the supplied temp directory')
t.eq(s.LR_export_useSubfolder, false, 'no subfolder is created')
t.eq(s.LR_collisionHandling, 'rename', 'a name collision gets a new file: each rendition lives until the model reads it')

t.suite('GrRendition — temp directory naming')

local LrFileUtils = require 'LrFileUtils'
LrFileUtils._reset()

local dir = Rendition.createTempDir('r-20261002T120000Z-abcd')
t.contains(dir, 'genreator-', 'temp directory is namespaced to the plugin')
t.contains(dir, 'r-20261002T120000Z-abcd', 'temp directory carries the run id')
t.contains(dir, '/tmp', 'temp directory sits under the OS temp path')
t.ok(LrFileUtils._dirs[dir] == true, 'temp directory is created')

-- Removal must be idempotent so the cleanup handler can run on any path
Rendition.removeTempDir(dir)
t.ok(#LrFileUtils._deleted >= 1, 'removeTempDir deletes the directory')
local deletedCount = #LrFileUtils._deleted
Rendition.removeTempDir(dir)
t.eq(#LrFileUtils._deleted, deletedCount,
     'removing an already-removed directory is a no-op, not an error')
Rendition.removeTempDir(nil)
t.eq(#LrFileUtils._deleted, deletedCount, 'removing nil is a no-op')

t.suite('GrRendition — stale directory cleanup')

LrFileUtils._reset()
LrFileUtils._dirs['/tmp/genreator-r-old-1'] = true
LrFileUtils._dirs['/tmp/genreator-r-old-2'] = true
LrFileUtils._dirs['/tmp/genreator-r-current'] = true
LrFileUtils._dirs['/tmp/something-else'] = true

Rendition.cleanStaleTempDirs('/tmp/genreator-r-current')

local deleted = {}
for _, p in ipairs(LrFileUtils._deleted) do deleted[p] = true end

t.ok(deleted['/tmp/genreator-r-old-1'], 'removes a stale genreator directory')
t.ok(deleted['/tmp/genreator-r-old-2'], 'removes a second stale directory')
t.ok(not deleted['/tmp/genreator-r-current'],
     'keeps the current run directory')
t.ok(not deleted['/tmp/something-else'],
     'never touches directories belonging to anything else')

return t
