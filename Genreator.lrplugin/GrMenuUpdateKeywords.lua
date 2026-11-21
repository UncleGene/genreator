-- Menu entry: Update Genre Keywords — bring the selection's genre keywords and fields back in
-- line after hand edits (ADR-019): one `Genre > X` per genre, and the Primary Genre / Primary
-- Group / Secondary Genres fields rewritten from them.
-- The photograph's own keywords are the decision; review state and decisions are unchanged.
require('GrReviewCommand').run('Update Genre Keywords', 'Updated', nil, function()
  return { fromKeywords = true }
end)
