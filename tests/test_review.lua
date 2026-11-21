--[[
Tests for GrKeywords (the keyword invariants, ADR-012 / R5.5) and GrReview (accept,
correct, No genre, Add / Remove Genre, reverts), end to end against a catalog stub that models Lightroom's
keyword tree and its "not usable until withWriteAccessDo returns" rule.
]]

local t = require 'harness'
local Keywords = require 'GrKeywords'
local Review = require 'GrReview'
local Metadata = require 'GrMetadata'
local Photo = require 'photo'
local LrApplication = import 'LrApplication'
local LrTasks = import 'LrTasks'

local F = Metadata.FIELDS

-- ------------------------------------------------------------------ plan (pure)

local function kw(branch, name) return { branch = branch, name = name, ref = (branch or '') .. '>' .. name } end
local function adds(p)
  local out = {}
  for _, a in ipairs(p.add) do out[#out + 1] = a[1] .. ' > ' .. a[2] end
  return out
end

t.suite('GrKeywords.plan — the invariants (ADR-019)')

local p = Keywords.plan({}, { primary = 'Street', genres = { 'Street', 'Portrait', 'Documentary' } })
t.eq(adds(p), { 'Genre > Street', 'Genre > Portrait', 'Genre > Documentary' },
     'a fresh decision writes every genre, the primary included, and nothing else')

p = Keywords.plan({}, { primary = 'Landscape', genres = { 'Nature' } })
t.eq(adds(p), { 'Genre > Landscape', 'Genre > Nature' },
     'the primary is always a genre: a primary missing from genres is added under Genre')

local current = { kw('Genre', 'Street'), kw('Genre', 'Portrait'), kw('Genre', 'Documentary') }
p = Keywords.plan(current, { primary = 'Portrait', genres = { 'Street', 'Portrait', 'Documentary' } })
t.eq({ #p.remove, #p.add }, { 0, 0 }, 'changing only the primary changes no keyword: it is a field')

p = Keywords.plan(current, { primary = 'Landscape', genres = { 'Street', 'Landscape' } })
t.eq(p.remove, { 'Genre>Portrait', 'Genre>Documentary' }, 'dropped genres are removed')
t.eq(adds(p), { 'Genre > Landscape' }, 'the new primary is added as a genre')

p = Keywords.plan({}, { primary = nil, genres = { 'Street', 'Portrait' } })
t.eq(adds(p), { 'Genre > Street', 'Genre > Portrait' }, 'no primary: the genres are still written')

p = Keywords.plan({ kw('Genre', 'Street'), kw('Genre', 'Street') }, { primary = 'Street', genres = { 'Street' } })
t.eq(#p.remove, 1, 'a duplicated Genre keyword is collapsed')

local foreign = { kw('Genre', 'Wedding'), kw(nil, 'Street'), kw(nil, 'PERSONAL'), kw('Genre', 'Street') }
p = Keywords.plan(foreign, { primary = nil, genres = {} })
t.eq(p.remove, { 'Genre>Street' }, 'removing genres touches managed keywords only — a user\'s own ' ..
     'Genre > Wedding, a Street outside Genre and PERSONAL are untouched')

p = Keywords.plan({}, { primary = 'No genre', genres = {} })
t.eq(#p.add, 0, 'No genre never becomes a keyword (ADR-022)')
p = Keywords.plan(current, { primary = 'No genre', genres = { 'Street' } })
t.eq(#p.remove, 3, 'No genre takes no genres, whatever the list says')

t.suite('GrKeywords.wanted / held — the genre fields (ADR-019)')

local w = Keywords.wanted { primary = 'Portrait', genres = { 'Street', 'Portrait', 'Documentary' } }
t.eq({ w.primary, w.secondaries, w.genres },
     { 'Portrait', { 'Street', 'Documentary' }, { 'Portrait', 'Street', 'Documentary' } },
     'the primary first, then the secondaries in the decision\'s (priority) order')
w = Keywords.wanted { primary = 'No genre', genres = { 'Street' } }
t.eq({ w.primary, #w.secondaries, #w.genres }, { 'No genre', 0, 0 }, 'No genre: the field value, no genres')
w = Keywords.wanted { primary = nil, genres = { 'Street' } }
t.eq({ w.primary, w.secondaries }, { nil, { 'Street' } }, 'no primary yet (pre-tagged): genres only')

t.eq(Keywords.held({ kw('Genre', 'Nature'), kw(nil, 'Portrait'), kw('Genre', 'Landscape') }, 'Landscape'),
     { primary = 'Landscape', genres = { 'Landscape', 'Nature' } },
     'held: genres from Genre keywords only, the primary from the field')
t.eq(Keywords.held({ kw('Genre', 'Nature'), kw('Genre', 'Street') }, 'Nature', { 'Nature', 'Street' }).genres,
     { 'Nature', 'Street' }, 'held keeps the recorded order')
t.eq(Keywords.held({ kw('Genre', 'Nature') }, 'No genre'), { primary = 'Nature', genres = { 'Nature' } },
     'a genre keyword added by hand to a No genre photograph becomes its primary')

-- ------------------------------------------------------------------ decisions (pure)

t.suite('GrReview — decisions')

local d = Review.acceptDecision { aiGenre = 'Street', aiGenres = 'Street, Documentary' }
t.eq(d.state, 'accepted', 'accept')
t.eq(d.genres, { 'Street', 'Documentary' }, 'accept keeps every suggested genre')
local ng = Review.acceptDecision { aiGenre = 'No genre', aiGenres = '' }
t.eq({ ng.state, ng.primary, #ng.genres }, { 'accepted', 'No genre', 0 }, 'accepting a No genre suggestion records No genre')
local none, reason = Review.acceptDecision { aiGenre = '' }
t.isNil(none, 'nothing to accept without a suggestion')
t.contains(reason, 'no suggestion', 'and says so')
none, reason = Review.acceptDecision { aiGenre = 'Scenic' }
t.contains(reason, 'not in the current taxonomy', 'a suggestion from a retired taxonomy is not accepted blindly')

d = Review.correctDecision({ aiGenre = 'Street', aiGenres = 'Street, Documentary' }, 'Street', { 'Documentary' })
t.eq(d.state, 'accepted', 'choosing exactly the suggestion counts as accepted (honest calibration)')
d = Review.correctDecision({ aiGenre = 'Nature', aiGenres = 'Nature' }, 'Landscape', { 'Nature' })
t.eq(d.state, 'corrected', 'a different choice counts as corrected')
t.eq(d.genres, { 'Landscape', 'Nature' }, 'the primary leads the genres')

-- ------------------------------------------------------------------ end to end

t.suite('GrReview.run — accept, change primary, reject, against the catalog stub')

local photo = Photo.new { keywords = { 'PERSONAL' },
  plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Street', [F.aiGenres] = 'Street, Portrait, Documentary' } }
local catalog = LrApplication._fakeCatalog { photo }
LrApplication._setCatalog(catalog)

local counts = Review.run(catalog, { photo }, Review.acceptDecision, 'Genreator: Accept Suggestion')
t.eq(counts.done, 1, 'accepted one photo')
t.eq(photo:_keywordPaths(), { 'Genre > Documentary', 'Genre > Portrait', 'Genre > Street', 'PERSONAL' },
     'the rodeo example, written as specified')
for _, k in ipairs(photo._keywords) do
  if k._parent then
    t.ok(not k._parent._includeOnExport and not k._includeOnExport,
         k._parent._name .. ' > ' .. k._name .. ' is created without Include on Export (R5.2)')
  end
end
t.eq({ photo._plugin[F.primaryGenre], photo._plugin[F.secondaryGenres] },
     { 'Street', 'Portrait, Documentary' }, 'the genre fields copy the keywords (ADR-019)')
t.eq(#catalog._writeTitles, 2, 'two write gates: create keywords, then assign (Lightroom rule)')
t.eq(photo._plugin[F.reviewState], 'accepted', 'state accepted')
t.eq(photo._plugin[F.humanGenre], 'Street', 'humanGenre recorded (calibration truth)')
t.eq(photo._plugin[F.humanGenres], 'Street, Portrait, Documentary', 'humanGenres recorded')

Review.run(catalog, { photo }, function(fields)
  return Review.correctDecision(fields, 'Portrait', { 'Street', 'Portrait', 'Documentary' })
end, 'Genreator: Correct Genres')
t.eq(photo:_keywordPaths(), { 'Genre > Documentary', 'Genre > Portrait', 'Genre > Street', 'PERSONAL' },
     'changing the primary keeps every genre')
t.eq({ photo._plugin[F.primaryGenre], photo._plugin[F.secondaryGenres] }, { 'Portrait', 'Street, Documentary' },
     'and the fields follow')
t.eq(photo._plugin[F.reviewState], 'corrected', 'state corrected')

Review.run(catalog, { photo }, function(fields) return Review.setPrimaryDecision(fields, 'No genre') end,
           'Genreator: Set Primary Genre')
t.eq(photo:_keywordPaths(), { 'PERSONAL' }, 'No genre removes the genre keywords and nothing else')
t.eq({ photo._plugin[F.primaryGenre], photo._plugin[F.secondaryGenres] },
     { 'No genre', '' }, 'the Primary Genre field says No genre, so it can be filtered on (ADR-022)')
t.eq(photo._plugin[F.reviewState], 'corrected', 'state corrected')
t.eq(photo._plugin[F.humanGenre], 'No genre', 'the decision is recorded')

t.suite('GrReview — Add / Remove Genre edit the list under review (R6.9)')

do
  local base = { reviewState = 'suggested', aiGenre = 'Landscape', aiGenres = 'Landscape, Nature, Portrait',
                 aiRanking = 'Lan* Nat* Por* Str Eve Doc Arc Obj' }
  local function with(extra) local f = {}; for k, v in pairs(base) do f[k] = v end
    for k, v in pairs(extra or {}) do f[k] = v end; return f end

  local d = Review.genreEditDecision(with(), 'Portrait', '-')
  t.eq(d, { keepKeywords = true, reviewGenres = 'Landscape, Nature', reviewGenre = 'Landscape' },
       'remove: list without it, primary kept, no keywords, no state')
  t.eq(Review.genreEditDecision(with { reviewGenres = d.reviewGenres, reviewGenre = 'Landscape' }, 'Street', '+').reviewGenres,
       'Landscape, Nature, Street', 'add: placed by the model\'s ranking, on the edited list (ADR-023)')
  t.eq(Review.genreEditDecision(with { aiRanking = 'Str Lan* Nat* Por*' }, 'Street', '+').reviewGenres,
       'Landscape, Street, Nature, Portrait', 'a genre ranked above the others still follows the primary')

  -- Never fails on the list itself (user, 2026-10-05).
  t.eq(Review.genreEditDecision(with(), 'Street', '-'),
       { keepKeywords = true, reviewGenres = 'Landscape, Nature, Portrait', reviewGenre = 'Landscape' },
       'removing an absent genre changes nothing, and is not a failure')
  t.eq(Review.genreEditDecision(with(), 'Nature', '+').reviewGenres, 'Landscape, Nature, Portrait',
       'adding a listed genre changes nothing, and is not a failure')
  t.eq(Review.genreEditDecision(with(), 'Landscape', '-'),
       { keepKeywords = true, reviewGenres = 'Nature, Portrait', reviewGenre = 'Nature' },
       'removing the primary promotes the next listed genre')
  local last = Review.genreEditDecision(with { reviewGenres = 'Landscape', reviewGenre = 'Landscape' }, 'Landscape', '-')
  t.eq(last, { keepKeywords = true, reviewGenres = '', reviewGenre = 'No genre' },
       'removing the last genre leaves No genre')
  t.eq(Review.genreEditDecision(with { reviewGenres = '', reviewGenre = 'No genre' }, 'Street', '+'),
       { keepKeywords = true, reviewGenres = 'Street', reviewGenre = 'Street' },
       'adding to No genre makes it the primary')
  local acc0 = Review.acceptDecision(with { reviewGenres = '', reviewGenre = 'No genre' })
  t.eq({ acc0.state, acc0.primary, #acc0.genres }, { 'corrected', 'No genre', 0 },
       'accepting an emptied list records No genre: no keywords')
  local accP = Review.acceptDecision(with { reviewGenres = 'Nature, Portrait', reviewGenre = 'Nature' })
  t.eq({ accP.state, accP.primary, accP.genres }, { 'corrected', 'Nature', { 'Nature', 'Portrait' } },
       'accepting a promoted primary is a correction with that primary')

  local _, why = Review.genreEditDecision(with { reviewState = 'accepted' }, 'Nature', '-')
  t.contains(why, 'Correct Genres', 'decided photographs are left to Correct Genres…')
  _, why = Review.genreEditDecision(with(), 'Abstract', '+')
  t.contains(why, 'not a genre', 'names come from the taxonomy')

  local acc = Review.acceptDecision(with { reviewGenres = 'Landscape, Nature', reviewGenre = 'Landscape' })
  t.eq({ acc.state, acc.primary, acc.genres }, { 'corrected', 'Landscape', { 'Landscape', 'Nature' } },
       'accept applies the edits, and counts as a list correction')
  acc = Review.acceptDecision(with { reviewGenres = 'Landscape, Nature, Portrait', reviewGenre = 'Landscape' })
  t.eq(acc.state, 'accepted', 'an unedited list under review is a plain accept')
  acc = Review.acceptDecision(with())
  t.eq(acc.genres, { 'Landscape', 'Nature', 'Portrait' }, 'no list under review: the AI list (older photographs)')

  -- Through the catalog: Remove writes only reviewGenres; Accept then writes the edited keywords.
  local cat5 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat5)
  local ph = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Landscape',
                                    [F.aiGenres] = 'Landscape, Nature, Portrait' } }
  Review.run(cat5, { ph }, function(f) return Review.genreEditDecision(f, 'Portrait', '-') end, 'remove')
  t.eq({ ph._plugin[F.reviewGenres], ph._plugin[F.reviewGenre] }, { 'Landscape, Nature', 'Landscape' },
       'genres and primary under review written')
  t.eq(ph._plugin[F.aiGenres], 'Landscape, Nature, Portrait', 'the AI list is never changed')
  t.eq(ph._plugin[F.reviewState], 'suggested', 'still awaiting review')
  t.eq(#ph._addedKeywords, 0, 'no keyword yet (ADR-002)')
  Review.run(cat5, { ph }, Review.acceptDecision, 'accept')
  local names = {}
  for _, k in ipairs(ph._addedKeywords) do names[#names + 1] = k._parent._name .. '>' .. k._name end
  table.sort(names)
  t.eq(names, { 'Genre>Landscape', 'Genre>Nature' },
       'accept writes the edited list: no Portrait')
  t.eq(ph._plugin[F.humanGenres], 'Landscape, Nature', 'decision recorded with the edits')
  LrApplication._setCatalog(previous)
end

t.suite('GrReview — a genre the user added by hand after the suggestion is kept')

do
  local f = { reviewState = 'suggested', aiGenre = 'Landscape', aiGenres = 'Landscape', userGenres = '',
              reviewGenre = 'Landscape', reviewGenres = 'Landscape', modelVersion = 'v7' }
  -- A suggestion writes no keyword, so the only genre keyword on it is the hand-added one.
  local d = Review.withLaterTags(Review.acceptDecision(f), f, { 'Nature' })
  t.eq({ d.state, d.primary, d.genres, d.laterUserGenres }, { 'corrected', 'Landscape', { 'Landscape', 'Nature' }, { 'Nature' } },
       'Accept keeps a hand-added genre and records it as a later user genre')
  local ng = { reviewState = 'suggested', aiGenre = 'No genre', aiGenres = '', userGenres = '',
               reviewGenre = 'No genre', reviewGenres = '' }
  d = Review.withLaterTags(Review.acceptDecision(ng), ng, { 'Street' })
  t.eq({ d.primary, d.genres }, { 'Street', { 'Street' } }, 'on a No genre suggestion it becomes the primary')
  d = Review.withLaterTags(Review.setPrimaryDecision(f, 'No genre'), f, { 'Nature' })
  t.eq({ d.primary, #d.genres }, { 'No genre', 0 }, 'an explicit No genre is the user\'s word over it')
  d = Review.withLaterTags(Review.correctDecision(f, 'Landscape', { 'Landscape' }), f, { 'Nature' })
  t.eq(d.genres, { 'Landscape' }, 'Correct Genres… sets an exact list')

  local cat8 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat8)
  local ph = Photo.new { keywordPaths = { 'Genre > Nature' }, plugin = {
    [F.reviewState] = 'suggested', [F.aiGenre] = 'Landscape', [F.aiGenres] = 'Landscape', [F.userGenres] = '',
    [F.reviewGenre] = 'Landscape', [F.reviewGenres] = 'Landscape', [F.modelVersion] = 'v7' } }
  Review.run(cat8, { ph }, Review.acceptDecision, 'accept')
  t.eq(#ph._removedKeywords, 0, 'through the catalog: Accept removes no hand-added genre')
  t.eq(ph._plugin[F.humanGenres], 'Landscape, Nature', 'it is part of the decision')
  t.eq(ph._plugin[F.laterUserGenres], 'Nature', 'and recorded as a later user genre')
  t.eq(ph._plugin[F.decisionModelVersion], 'v7', 'the decision records the model version it answered')
  LrApplication._setCatalog(previous)
end

t.suite('GrReview — Set Primary Genre keeps each photograph\'s own genres')

do
  local sug = { reviewState = 'suggested', aiGenre = 'Landscape', aiGenres = 'Landscape, Nature',
                reviewGenre = 'Landscape', reviewGenres = 'Landscape, Nature' }
  local d = Review.setPrimaryDecision(sug, 'Nature')
  t.eq({ d.state, d.primary, d.genres }, { 'corrected', 'Nature', { 'Nature', 'Landscape' } },
       'a listed genre becomes primary; the old primary stays as a genre')
  d = Review.setPrimaryDecision(sug, 'Street')
  t.eq(d.genres, { 'Street', 'Landscape', 'Nature' }, 'a missing genre is added as the primary; nothing removed')
  d = Review.setPrimaryDecision(sug, 'Landscape')
  t.eq(d.state, 'accepted', 'choosing the suggested primary on an unedited list is an accept')
  local edited = { reviewState = 'suggested', aiGenre = 'Landscape', aiGenres = 'Landscape, Nature, Object',
                   reviewGenre = 'Landscape', reviewGenres = 'Landscape, Nature' }
  t.eq(Review.setPrimaryDecision(edited, 'Nature').genres, { 'Nature', 'Landscape' },
       'starts from the genres under review (step-1 edits kept)')
  local decided = { reviewState = 'corrected', aiGenre = 'Street', aiGenres = 'Street',
                    humanGenre = 'Portrait', humanGenres = 'Portrait, Documentary' }
  t.eq(Review.setPrimaryDecision(decided, 'Documentary').genres, { 'Documentary', 'Portrait' },
       'a decided photograph starts from the user\'s own list')
  local nothing = { reviewState = 'corrected', aiGenre = 'Street', aiGenres = 'Street, Documentary',
                    humanGenre = 'No genre', humanGenres = '' }
  t.eq(Review.setPrimaryDecision(nothing, 'Object').genres, { 'Object' }, 'from No genre: just the new primary')
  local cleared = Review.setPrimaryDecision(sug, 'No genre')
  t.eq({ cleared.primary, #cleared.genres }, { 'No genre', 0 }, 'No genre clears the genres')
  local _, why = Review.setPrimaryDecision({ reviewState = 'unclassified' }, 'Street')
  t.contains(why, 'not classified', 'an unclassified photograph is skipped')
  _, why = Review.setPrimaryDecision(sug, 'Abstract')
  t.contains(why, 'not a genre', 'names come from the taxonomy')

  -- Several photographs, one command: each keeps its own genres (the reported defect).
  local cat6 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat6)
  local a = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Landscape',
    [F.aiGenres] = 'Landscape, Nature', [F.reviewGenre] = 'Landscape', [F.reviewGenres] = 'Landscape, Nature' } }
  local b = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Object',
    [F.aiGenres] = 'Object, Architecture', [F.reviewGenre] = 'Object', [F.reviewGenres] = 'Object, Architecture' } }
  Review.run(cat6, { a, b }, function(fields) return Review.setPrimaryDecision(fields, 'Street') end, 'set primary')
  t.eq({ a._plugin[F.humanGenre], a._plugin[F.humanGenres] }, { 'Street', 'Street, Landscape, Nature' },
       'photo 1: Street primary, its own genres kept')
  t.eq({ b._plugin[F.humanGenre], b._plugin[F.humanGenres] }, { 'Street', 'Street, Architecture, Object' },
       'photo 2: Street primary, its own (different) genres kept (no ranking: taxonomy order)')
  LrApplication._setCatalog(previous)
end

t.suite('GrReview.run — several photographs: each keyword looked up once, never while assigning')

do
  -- Lightroom returned nil for a repeated createKeyword(returnExisting) of an existing
  -- keyword within one multi-photo accept (2026-10-05). Lookups must not repeat.
  local cat4 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat4)
  local calls, inAssignGate = {}, 0
  local real = cat4.createKeyword
  function cat4:createKeyword(name, syn, inc, parent, ret)
    local key = (parent and parent._name or '') .. '/' .. name
    calls[key] = (calls[key] or 0) + 1
    if self._writeTitles[#self._writeTitles] == 'multi' then inAssignGate = inAssignGate + 1 end
    return real(self, name, syn, inc, parent, ret)
  end
  local photos = {}
  for i = 1, 4 do
    photos[i] = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Portrait',
                                       [F.aiGenres] = 'Portrait, Street' } }
  end
  local c = Review.run(cat4, photos, Review.acceptDecision, 'multi')
  t.eq(c.done, 4, 'all four accepted')
  t.eq(calls['Genre/Portrait'], 1, 'Genre > Portrait looked up once for four photographs')
  t.eq(calls['/Genre'], 1, 'the Genre parent looked up once')
  t.eq(inAssignGate, 0, 'no keyword lookup inside the assigning gate')
  t.eq(#photos[4]._addedKeywords, 2, 'the last photograph still gets all its keywords')
  LrApplication._setCatalog(previous)
end

t.suite('GrReview.run — a failed write names the photo and the SDK call')

do
  local cat3 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat3)
  local ok1 = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Street', [F.aiGenres] = 'Street' } }
  local bad = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Street', [F.aiGenres] = 'Street' } }
  function bad:addKeyword() error('assertion failed!', 0) end   -- what Lightroom reported
  local okRun, err = LrTasks.pcall(function()
    Review.run(cat3, { ok1, bad }, Review.acceptDecision, 'accept')
  end)
  t.ok(not okRun, 'the failure surfaces')
  t.contains(tostring(err), 'photo 2 of 2, addKeyword Genre > Street', 'names the photo and the call')
  t.contains(tostring(err), 'assertion failed!', 'keeps Lightroom\'s message')
  LrApplication._setCatalog(previous)
end

t.suite('GrReview.run — cancel while reading changes nothing')

do
  local Scope = require 'LrProgressScope'
  Scope._reset(); Scope._cancelAfter = 1
  local cat2 = LrApplication._fakeCatalog {}
  local p1 = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Street', [F.aiGenres] = 'Street' } }
  local p2 = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Street', [F.aiGenres] = 'Street' } }
  local c = Review.run(cat2, { p1, p2 }, Review.acceptDecision, 'accept', Scope { title = 't' })
  Scope._reset()
  t.ok(c.cancelled, 'reported as cancelled')
  t.eq(#cat2._writeTitles, 0, 'no write gate was opened')
  t.eq(p1._plugin[F.reviewState], 'suggested', 'the first photograph is untouched')
  t.eq(Review.summary(c, 'Accepted'), 'Cancelled — nothing was changed.', 'the dialog says so')
end

t.suite('GrReview.run — skips are explained, reverts touch only their own area')

local fresh = Photo.new { plugin = {} }
catalog = LrApplication._fakeCatalog { fresh }
LrApplication._setCatalog(catalog)
counts = Review.run(catalog, { fresh }, Review.acceptDecision, 'Genreator: Accept Suggestion')
t.eq(counts.done, 0, 'nothing accepted without a suggestion')
t.contains(Review.summary(counts, 'Accepted'), 'no suggestion to accept', 'the summary says why')

local decided = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = 'Landscape', [F.aiGenres] = 'Landscape' } }
catalog = LrApplication._fakeCatalog { decided }
LrApplication._setCatalog(catalog)
Review.run(catalog, { decided }, Review.acceptDecision, 'accept')
Review.run(catalog, { decided }, function() return { keepKeywords = true, clearData = true } end, 'clear')
t.eq(decided._plugin[F.reviewState], 'unclassified', 'Clear Plugin Data resets the fields')
t.eq(decided:_keywordPaths(), { 'Genre > Landscape' }, 'and leaves keywords alone')
t.eq(decided._plugin[F.primaryGenre], 'Landscape', 'and the genre fields that copy them')
Review.run(catalog, { decided }, function() return { primary = nil, genres = {} } end, 'remove')
t.eq(#decided:_keywordPaths(), 0, 'Remove Genre Keywords removes them')
t.eq(decided._plugin[F.primaryGenre], '', 'and empties the genre fields')

t.suite('GrReview.run — Update Genre Keywords repairs hand-edited keywords (ADR-019)')

do
  local cat7 = LrApplication._fakeCatalog {}
  local previous = LrApplication._catalog
  LrApplication._setCatalog(cat7)
  local function tree(parentName, name)
    local parent = LrApplication._newKeyword(parentName, nil, true, cat7)
    return LrApplication._newKeyword(name, parent, true, cat7)
  end
  -- Accepted as Street alone; Portrait was then added by hand, and Street keyword duplicated.
  local old = Photo.new { keywords = { 'PERSONAL' }, plugin = { [F.reviewState] = 'accepted',
    [F.humanGenre] = 'Street', [F.humanGenres] = 'Street', [F.primaryGenre] = 'Street',
    [F.secondaryGenres] = '' } }
  for _, k in ipairs { tree('Genre', 'Street'), tree('Genre', 'Portrait'), tree('Genre', 'Street') } do
    old._keywords[#old._keywords + 1] = k
  end
  local none = Photo.new { plugin = { [F.reviewState] = 'accepted', [F.primaryGenre] = 'No genre' } }
  local update = function() return { fromKeywords = true } end

  local c = Review.run(cat7, { old, none }, update, 'update')
  t.eq(c.done, 1, 'one photograph updated')
  t.eq(old:_keywordPaths(), { 'Genre > Portrait', 'Genre > Street', 'PERSONAL' },
       'one Genre keyword per genre; other keywords kept')
  t.eq({ old._plugin[F.primaryGenre], old._plugin[F.secondaryGenres] },
       { 'Street', 'Portrait' }, 'the genre fields follow the keywords')
  t.eq({ old._plugin[F.reviewState], old._plugin[F.humanGenre] }, { 'accepted', 'Street' },
       'review state and the recorded decision are unchanged')

  c = Review.run(cat7, { old, none }, update, 'update again')
  t.eq(c.done, 0, 'running it again changes nothing')
  t.eq(c.reasons['already up to date'], 2, 'and says why')
  LrApplication._setCatalog(previous)
end

t.suite('Reclassify never overrides a human decision (R2.7)')

local human = Photo.new { plugin = { [F.reviewState] = 'corrected', [F.humanGenre] = 'Landscape',
                                     [F.aiGenre] = 'Nature' } }
Metadata.writeSuggestion(human, { primary = 'Street', genres = { 'Street' } }, {})
t.eq(human._plugin[F.reviewState], 'corrected', 'state stays corrected')
t.eq(human._plugin[F.humanGenre], 'Landscape', 'the confirmed genre stands')
t.eq(human._plugin[F.aiGenre], 'Street', 'while the AI fields are refreshed for comparison')
Metadata.writeError(human, 'timeout', 'slow', {})
t.eq(human._plugin[F.reviewState], 'corrected', 'a failed reclassification does not erase the decision')

t.suite('GrReview — re-deriving a personal suggestion from the stored ranking (ADR-028)')

do
  local Model = require 'GrModel'
  local Taxonomy = require 'GrTaxonomy'
  local G = Taxonomy.genres
  local s1, s2, s3 = Taxonomy.short(G[1]), Taxonomy.short(G[2]), Taxonomy.short(G[3])
  local marked = s1 .. '* ' .. s2 .. '*+ ' .. s3 .. ' floor=0.5'
  local function f(over)
    local x = { reviewState = 'suggested', personal = 'yes', aiRanking = marked,
                aiGenre = G[2], aiGenres = G[2], userGenres = '' }
    for k, v in pairs(over or {}) do x[k] = v end
    return x
  end
  local d = Review.rederiveDecision(f(), {}, 'off', 0.5)
  t.eq(d and d.rederived.genres, { G[1], G[2] }, 'cut-offs only: every genre reaching its cut-off')
  t.eq(d and d.keepKeywords, true, '... and no keyword is written')
  local _, why = Review.rederiveDecision(f(), {}, 'recommended', 0.5)
  t.eq(why, 'unchanged', 'the same answer again changes nothing, so review edits stay')
  d = Review.rederiveDecision(f { aiGenre = G[1], aiGenres = G[1] .. ', ' .. G[2] }, {}, 'recommended', 0.5)
  t.eq(d and d.rederived, { primary = G[2], genres = { G[2] }, laterUserGenres = {} },
       'the recommended floor: the first genre over it is the primary')
  d = Review.rederiveDecision(f(), { G[3] }, 'recommended', 0.5)
  t.eq(d and d.rederived.genres, { G[2], G[3] }, 'a genre keyword the user added since joins, as on reclassifying')
  d = Review.rederiveDecision(f { aiRanking = '-* ' .. marked }, {}, 'off', 0.5)
  t.eq(d and d.rederived.primary, Taxonomy.NO_GENRE, 'the model\'s no-genre answer still comes first')
  _, why = Review.rederiveDecision(f { reviewState = 'accepted' }, {}, 'off', 0.5)
  t.contains(why, 'a decision stands', 'a decided photograph is left alone (R2.7)')
  _, why = Review.rederiveDecision(f { personal = 'no' }, {}, 'off', 0.5)
  t.contains(why, 'not personal', 'the setting does not touch a photograph that is not personal')
  _, why = Review.rederiveDecision(f { aiRanking = '' }, {}, 'off', 0.5)
  t.contains(why, 'reclassify', 'without a stored ranking: reclassify')
  local before = s1 .. '* ' .. s2 .. '* ' .. s3
  _, why = Review.rederiveDecision(f { aiRanking = before }, {}, 'recommended', 0.5)
  t.contains(why, 'before the model had a personal floor', 'a ranking stored without floor marks cannot get the floor')
  d = Review.rederiveDecision(f { aiRanking = before }, {}, 'off', 0.5)
  t.eq(d and d.rederived.genres, { G[1], G[2] }, '... but can go back to the cut-offs alone')
  _, why = Review.rederiveDecision(f { aiRanking = before, aiGenres = G[1] .. ', ' .. G[2], aiGenre = G[1] },
                                   {}, 'recommended', nil)
  t.eq(why, 'unchanged', 'with a model that has no floor, the recommended setting is the cut-offs')
  t.eq(Model.FLOOR_MODES.off, 'off', 'the setting\'s values are GrConfig\'s')
end

t.suite('GrReview — the review trail (ADR-027)')

local TG = require('GrTaxonomy').genres
t.eq(Metadata.trailEntry(1793000000, 'rm:' .. TG[8], 14, '1 Genre: ' .. TG[8]),
     '1793000000 rm:' .. TG[8] .. ' n=14 @1 Genre: ' .. TG[8], 'an entry: time, command, selection size, grid')
t.eq(Metadata.trailEntry(1, 'accept', 1, nil), '1 accept n=1 @-', 'no single source: a dash')
t.eq(Metadata.trailEntry(1, 'accept', 1, 'a;b'), '1 accept n=1 @a,b', 'a ; in a grid name cannot split the trail')
t.eq(Metadata.trailWith('', 'x'), 'x', 'the first entry')
t.eq(Metadata.trailWith('x; y', 'z'), 'x; y; z', 'appended, oldest first')
local long = ''
for i = 1, Metadata.TRAIL_MAX + 5 do long = Metadata.trailWith(long, 'e' .. i) end
t.eq(select(2, long:gsub(';', ';')) + 1, Metadata.TRAIL_MAX, 'only the last entries are kept')
t.ok(long:sub(-#('e' .. (Metadata.TRAIL_MAX + 5))) == 'e' .. (Metadata.TRAIL_MAX + 5), '... the newest last')

local tp = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.aiGenre] = TG[1],
                                  [F.aiGenres] = TG[1] .. ', ' .. TG[2], [F.reviewGenre] = TG[1],
                                  [F.reviewGenres] = TG[1] .. ', ' .. TG[2] } }
local tc = LrApplication._fakeCatalog { tp }
LrApplication._setCatalog(tc)
Review.run(tc, { tp }, function(f) return Review.genreEditDecision(f, TG[2], '-') end, 'remove', nil, 'E1')
t.eq(tp._plugin[F.reviewTrail], 'E1', 'a genre edit is recorded')
Review.run(tc, { tp }, Review.acceptDecision, 'accept', nil, 'E2')
t.eq(tp._plugin[F.reviewTrail], 'E1; E2', 'then the decision, after it')
Review.run(tc, { tp }, Review.acceptDecision, 'accept')
t.eq(tp._plugin[F.reviewTrail], 'E1; E2', 'a command without a trail entry leaves it')
Metadata.writeSuggestion(tp, { primary = TG[1], genres = { TG[1] } }, {})
t.eq(tp._plugin[F.reviewTrail], 'E1; E2', 'a reclassified decision keeps the trail of its review')
local fresh2 = Photo.new { plugin = { [F.reviewState] = 'suggested', [F.reviewTrail] = 'old' } }
Metadata.writeSuggestion(fresh2, { primary = TG[1], genres = { TG[1] } }, {})
t.eq(fresh2._plugin[F.reviewTrail], '', 'a new suggestion starts a new trail')

LrApplication._setCatalog(nil)
return t
