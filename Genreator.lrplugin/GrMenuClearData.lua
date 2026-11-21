-- Menu entry: Clear Plugin Data — reset every Genreator field to unclassified. Keywords
-- are left alone (use Remove Genre Keywords for those).
require('GrReviewCommand').run('Clear Plugin Data', 'Cleared', nil, function()
  return { keepKeywords = true, clearData = true }
end)
