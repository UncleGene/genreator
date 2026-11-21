--[[
Menu entry: Correct Genres… — choose the Primary Genre and the additional Genres yourself.

Genre names come from the taxonomy. The dialog opens on the target photo's state (an earlier
decision, else the suggestion with any Add / Remove Genre edits) and applies the result to
every selected photograph. No genre takes no genres (ADR-022). The decision is recorded as
`accepted` when it matches the suggestion and `corrected` otherwise
(GrReview.correctDecision).
]]

local LrBinding = import 'LrBinding'
local LrDialogs = import 'LrDialogs'
local LrView    = import 'LrView'

local function prepare(photos, cfg, context)
  local Metadata = require 'GrMetadata'
  local Review   = require 'GrReview'
  local Taxonomy = require 'GrTaxonomy'

  local F = Metadata.FIELDS
  local target = photos[1]
  local human = Metadata.get(target, F.humanGenre)
  local primary, genres
  if human and human ~= '' and Taxonomy.isPrimary(human) then
    primary, genres = human, Review.genreList(Metadata.get(target, F.humanGenres))
  else
    local fields = { aiGenre = Metadata.get(target, F.aiGenre), aiGenres = Metadata.get(target, F.aiGenres),
                     reviewGenre = Metadata.get(target, F.reviewGenre),
                     reviewGenres = Metadata.get(target, F.reviewGenres) }
    primary = Review.primaryUnderReview(fields)
    genres = Review.underReview(fields)
  end
  if not Taxonomy.isPrimary(primary) then primary = Taxonomy.genres[1] end

  local props = LrBinding.makePropertyTable(context)
  props.primary = primary
  local checked = {}
  for _, g in ipairs(genres) do checked[g] = true end
  for i, g in ipairs(Taxonomy.genres) do props['g' .. i] = checked[g] == true or g == primary end

  local f = LrView.osFactory()
  local items = {}
  for _, g in ipairs(Taxonomy.genres) do items[#items + 1] = { title = g, value = g } end
  items[#items + 1] = { title = Taxonomy.NO_GENRE, value = Taxonomy.NO_GENRE }
  local boxes = { spacing = f:label_spacing() }
  for i, g in ipairs(Taxonomy.genres) do
    boxes[#boxes + 1] = f:checkbox { title = g, value = LrView.bind('g' .. i) }
  end

  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    f:static_text {
      title = #photos == 1 and 'Applies to the selected photograph.' or string.format(
        'All %d selected photographs get exactly this Primary Genre and these Genres, replacing ' ..
        'their own. To change only the primary and keep each photograph\'s other genres, ' ..
        'use Set Primary Genre… instead.', #photos),
      width_in_chars = 60, height_in_lines = #photos == 1 and 1 or 3,
    },
    f:row {
      f:static_text { title = 'Primary Genre:', alignment = 'right', width = LrView.share('l') },
      f:popup_menu { items = items, value = LrView.bind('primary') },
    },
    f:row {
      f:static_text { title = 'Genres:', alignment = 'right', width = LrView.share('l') },
      f:column(boxes),
    },
    f:static_text {
      title = 'The Primary Genre is always included in Genres. No genre clears the Genres.',
      width_in_chars = 60, height_in_lines = 2,
    },
  }
  if LrDialogs.presentModalDialog { title = 'Correct Genres', contents = contents, actionVerb = 'Apply' } ~= 'ok' then
    return nil
  end

  local chosen = {}
  for i, g in ipairs(Taxonomy.genres) do if props['g' .. i] then chosen[#chosen + 1] = g end end
  local chosenPrimary = props.primary
  return function(fields) return Review.correctDecision(fields, chosenPrimary, chosen) end, 'correct:' .. chosenPrimary
end

require('GrReviewCommand').run('Correct Genres', 'Recorded', prepare, nil)
