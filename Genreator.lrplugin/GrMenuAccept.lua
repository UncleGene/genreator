-- Menu entry: Accept Suggestion — adopt the suggested Primary Genre and Genres (with any
-- Add / Remove Genre edits) as keywords; a No genre suggestion is recorded as No genre.
local Review = require 'GrReview'
require('GrReviewCommand').run('Accept Suggestion', 'Accepted', nil, Review.acceptDecision, 'accept')
