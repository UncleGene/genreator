--[[
GrReviewCommand — the shared shell of every review menu command: an async task with a
failure handler, the effective config and taxonomy loaded, the selection read, the
decision applied by GrReview, and a summary shown.
]]

local LrApplication     = import 'LrApplication'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrProgressScope   = import 'LrProgressScope'

local Command = {}

--- @param name    task name and dialog title, e.g. 'Accept Suggestion'
-- @param verb     summary verb, e.g. 'Accepted'
-- @param prepare  optional function(photos, cfg) -> decide | nil (nil cancels quietly);
--                 used by Correct Genres… to show its dialog first
-- @param decide   function(fields) -> decision | nil, reason (when there is no prepare)
-- @param command  the review trail's name for the command (ADR-027), e.g. 'accept'; prepare
--                 may return its own as a second value ('rm:Object')
function Command.run(name, verb, prepare, decide, command)
  LrFunctionContext.postAsyncTaskWithContext('Genreator' .. name:gsub('%W', ''), function(context)
    context:addFailureHandler(function(_, message)
      require('GrLog').errorf('%s failed: %s', name, tostring(message))
      LrDialogs.message('Genreator: ' .. name .. ' failed', tostring(message), 'critical')
    end)

    local cfg, cfgErr = require('GrConfig').load()
    if not cfg then
      LrDialogs.message('Genreator: configuration problem', tostring(cfgErr), 'critical')
      return
    end

    local catalog = LrApplication.activeCatalog()
    local photos = catalog:getTargetPhotos() or {}
    if #photos == 0 then
      LrDialogs.message('Genreator', 'Select one or more photographs first.', 'info')
      return
    end

    -- Read before any dialog: the grid the command was chosen in.
    local Collections = require 'GrCollections'
    local grid = Collections.sourceLabel(Collections.activeSource(catalog))
    if prepare then
      decide, command = prepare(photos, cfg, context)
      if not decide then return end
    end
    local trail = command and require('GrMetadata').trailEntry(os.time(), command, #photos, grid) or nil

    local Review = require 'GrReview'
    local progress = LrProgressScope {
      title           = string.format('Genreator: %s (%d photographs)', name, #photos),
      functionContext = context,
    }
    progress:setCancelable(true)
    local counts = Review.run(catalog, photos, decide, 'Genreator: ' .. name, progress, trail)
    progress:done()
    local summary = Review.summary(counts, verb)
    require('GrLog').infof('%s on %d selected: %s', name, #photos, (summary:gsub('\n', '; ')))
    LrDialogs.message('Genreator: ' .. name, summary, 'info')
  end)
end

--- Add Genre (op '+') / Remove Genre (op '-') on the selected photographs' list under
-- review (R6.9). The genre is the one of the grid being viewed (a numbered grid in Step 1 · Genres) when there is
-- one — Remove from a genre grid needs no dialog — otherwise a one-menu dialog asks.
function Command.genreEdit(name, op)
  local function prepare(photos, cfg, context)
    local Review = require 'GrReview'
    local genre = require('GrCollections').activeGrid(import('LrApplication').activeCatalog())
    if not genre or op == '+' then
      genre = Command.askGenre(context, name, #photos, op == '+' and genre or nil, string.format(
        'Applies to %d selected photograph%s awaiting review. Accept applies the change.',
        #photos, #photos == 1 and '' or 's'))
      if not genre then return nil end
    end
    return function(fields) return Review.genreEditDecision(fields, genre, op) end,
           (op == '+' and 'add:' or 'rm:') .. genre
  end
  Command.run(name, 'Genre list updated, still awaiting review', prepare, nil)
end

--- Set Primary Genre…: one genre menu, No genre included; each selected photograph gets that
-- primary and keeps its own other genres (Review.setPrimaryDecision). Decides at once.
function Command.setPrimary(name)
  local function prepare(photos, cfg, context)
    local genre = Command.askGenre(context, name, #photos, nil, string.format(
      'Each of the %d selected photograph%s gets this Primary Genre, added to its genres if ' ..
      'missing. Every photograph keeps its own other genres; No genre removes them all. ' ..
      'Keywords are written now.', #photos, #photos == 1 and '' or 's'), true)
    if not genre then return nil end
    local Review = require 'GrReview'
    return function(fields) return Review.setPrimaryDecision(fields, genre) end, 'primary:' .. genre
  end
  Command.run(name, 'Recorded', prepare, nil)
end

--- A dialog with one genre menu, with No genre when `withNoGenre`. @return the choice, or
-- nil when cancelled.
function Command.askGenre(context, name, count, default, explanation, withNoGenre)
  local LrBinding = import 'LrBinding'
  local LrView    = import 'LrView'
  local Taxonomy  = require 'GrTaxonomy'
  local props = LrBinding.makePropertyTable(context)
  props.genre = default or Taxonomy.genres[1]
  local f = LrView.osFactory()
  local items = {}
  for _, g in ipairs(Taxonomy.genres) do items[#items + 1] = { title = g, value = g } end
  if withNoGenre then items[#items + 1] = { title = Taxonomy.NO_GENRE, value = Taxonomy.NO_GENRE } end
  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    f:row {
      f:static_text { title = 'Genre:' },
      f:popup_menu { items = items, value = LrView.bind('genre') },
    },
    f:static_text { title = explanation, width_in_chars = 50, height_in_lines = 3 },
  }
  if LrDialogs.presentModalDialog { title = name, contents = contents, actionVerb = name } ~= 'ok' then
    return nil
  end
  return props.genre
end

return Command
