-- Menu entry: Remove Genre — take a genre off the selected photographs' list under review
-- (R6.9). Inside a genre grid (Step 1 · Genres) it removes its genre with no dialog; Accept applies it later.
require('GrReviewCommand').genreEdit('Remove Genre', '-')
