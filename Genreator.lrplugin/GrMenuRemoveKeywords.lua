-- Menu entry: Remove Genre Keywords — drop the genre keywords (the taxonomy's names only)
-- from the selection, and the genre fields that copy them. The rest of the plugin metadata
-- is left as it is.
require('GrReviewCommand').run('Remove Genre Keywords', 'Cleared', nil, function()
  return { primary = nil, genres = {} }
end)
