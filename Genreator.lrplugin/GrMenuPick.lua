--[[
Menu entry: Library > Plug-in Extras > Pick Photos to Review… (temporary)

Asks for N, then lets the classifier score a random sample of about 5 × N unclassified
photographs of the selection (at most 500, or N if larger) and keep suggestions for N of them:
an equal share per suggested primary genre, the model's edges first (GrPick). They join the
other suggestions in Awaiting Review.
]]

local LrBinding         = import 'LrBinding'
local LrDialogs         = import 'LrDialogs'
local LrFunctionContext = import 'LrFunctionContext'
local LrView            = import 'LrView'

LrFunctionContext.postAsyncTaskWithContext('GenreatorPick', function(context)
  context:addFailureHandler(function(_, message)
    LrDialogs.message('Genreator: Pick Photos to Review failed', tostring(message), 'critical')
  end)

  local props = LrBinding.makePropertyTable(context)
  props.n = 50
  local f = LrView.osFactory()
  local contents = f:column {
    bind_to_object = props,
    spacing = f:control_spacing(),
    f:row {
      f:static_text { title = 'Photographs to pick:', alignment = 'right', width = LrView.share('l') },
      f:edit_field { value = LrView.bind('n'), min = 1, max = 2000, precision = 0, width_in_digits = 5, immediate = true },
    },
    f:static_text {
      title = 'From the unclassified photographs of the selection, the model scores a random ' ..
              'sample about five times as large (at most 500, or N if larger); each suggested ' ..
              'primary genre gets an equal share of the picks, where the model is least sure first. ' ..
              'Temporary: criteria ' .. require('GrPick').VERSION .. '.',
      width_in_chars = 50, height_in_lines = 6,
    },
  }
  if LrDialogs.presentModalDialog { title = 'Pick Photos to Review', contents = contents, actionVerb = 'Continue' } ~= 'ok' then
    return
  end
  local n = math.floor(tonumber(props.n) or 0)
  if n < 1 then
    LrDialogs.message('Genreator', 'Enter at least 1 photograph.', 'info')
    return
  end
  require('GrClassifier').classifySelection { pick = { n = n } }
end)
