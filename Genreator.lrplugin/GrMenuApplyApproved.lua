--[[
Menu entry: File > Plug-in Extras > Apply Approved Genres…

Picks an approved genres file and applies it to the photographs it names, wherever they are
in the catalog (GrApproved, ADR-025): each becomes a decided photograph with exactly the
approved genres, overriding what it had. Confirms first, with the counts.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFileUtils       = import 'LrFileUtils'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'

LrFunctionContext.postAsyncTaskWithContext('GenreatorApplyApproved', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: Apply Approved Genres failed', tostring(message), 'critical')
  end)

  local Approved = require 'GrApproved'
  local Review   = require 'GrReview'

  local paths = LrDialogs.runOpenPanel {
    title = 'Apply Approved Genres', prompt = 'Choose',
    canChooseFiles = true, canChooseDirectories = false, allowsMultipleSelection = false,
    fileTypes = { 'json' },
  }
  if not paths or not paths[1] then return end

  local parsed, err = Approved.parse(LrFileUtils.readFile(paths[1]))
  if not parsed then
    LrDialogs.message('Genreator: Apply Approved Genres', err, 'critical')
    return
  end

  local catalog = LrApplication.activeCatalog()
  local matched, skipped = Approved.match(catalog, parsed.items)
  local notes = {}
  for reason, n in pairs(skipped) do notes[#notes + 1] = string.format('Skipped %d: %s', n, reason) end
  if #parsed.invalid > 0 then
    notes[#notes + 1] = string.format('Invalid %d (first: %s)', #parsed.invalid, parsed.invalid[1])
  end
  table.sort(notes)

  if #matched == 0 then
    LrDialogs.message('Genreator: Apply Approved Genres', 'No photograph in this catalog matches the file.\n\n' ..
                      table.concat(notes, '\n'), 'info')
    return
  end
  local answer = LrDialogs.confirm(
    string.format('Apply approved genres to %d photograph%s?', #matched, #matched == 1 and '' or 's'),
    'Each gets exactly the approved genres, as a decided photograph: its genre keywords and ' ..
    'fields are replaced, and classifying again will not change them.\n\n' ..
    require('GrMetadata').SYNC_NOTE ..
    (#notes > 0 and ('\n\n' .. table.concat(notes, '\n')) or ''),
    'Apply', 'Cancel')
  if answer ~= 'ok' then return end

  local itemOf, photos = {}, {}
  for _, m in ipairs(matched) do
    photos[#photos + 1] = m.photo
    itemOf[m.photo] = m.item
  end
  local progress = LrProgressScope {
    title = string.format('Genreator: applying approved genres (%d photographs)', #photos),
    functionContext = context,
  }
  progress:setCancelable(true)
  local counts = Review.run(catalog, photos, function(fields, photo)
    return Approved.decision(fields, itemOf[photo], parsed.source)
  end, 'Genreator: Apply Approved Genres', progress)
  progress:done()

  local summary = Review.summary(counts, 'Applied')
  if not counts.cancelled and #notes > 0 then summary = summary .. '\n' .. table.concat(notes, '\n') end
  require('GrLog').infof('Apply Approved Genres: %s', (summary:gsub('\n', '; ')))
  LrDialogs.message('Genreator: Apply Approved Genres', summary, 'info')
end)
