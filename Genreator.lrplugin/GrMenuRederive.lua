-- Menu entry: Re-derive Personal Suggestions — apply the personalFloor setting (ADR-028) to
-- the selection's personal photographs awaiting review, from the stored ranking, without the
-- model. Decisions stand; a fresh suggestion starts a fresh review of it.
local Keywords = require 'GrKeywords'
local Model    = require 'GrModel'
local Review   = require 'GrReview'
require('GrReviewCommand').run('Re-derive Personal Suggestions', 'Re-derived', function(_, cfg)
  local floor = Model.personalFloor(Model.manifest())
  return function(fields, photo)
    return Review.rederiveDecision(fields, Keywords.held(Keywords.currentOf(photo)).genres,
                                   cfg.personalFloor, floor)
  end
end)
