--[[
GrKeywords — the `Genre` keyword branch, and the genre fields written with it (ADR-012,
ADR-019, R2.7, R5.5).

The ONLY place genre keywords are written. Invariants, all enforced by `plan`:

  1. a decided photograph has one `Genre > X` per genre, the primary included, and no other
     genre keyword. The primary and the secondaries live in plugin fields (`wanted`), which
     smart collections can tell apart; "no genre" is a Primary Genre value with no keyword;
  2. only children of the top-level `Genre` named after the taxonomy's genres are ever
     touched — any other keyword, including a user's own child of `Genre`, is left alone
     (R5.6).

The user's own `Genre > X` keywords on a photograph not yet categorized are pre-tags
(ADR-023): classification reads them and never removes them. The Personal keyword (config
`personalKeyword`, default `#PERSONAL`) and everything nested under it mark a photograph
personal (ADR-024); the plugin reads them, creates the keyword if it is missing on request,
and never assigns or removes it.

Genre keywords are created with Include on Export off (R5.2): they are catalog
organisation, not part of the delivered file.

Lightroom constraint: a keyword created inside withWriteAccessDo cannot be assigned until
that call returns, so `apply` uses two gates — create, then assign.

Pure: wanted, held, plan, under. Lightroom-bound: currentOf, ensureTree, ensurePath, assign.
]]

local Taxonomy = require 'GrTaxonomy'

local Keywords = {}

Keywords.GENRE = 'Genre'

-- Include on Export for the keywords created (R5.2).
local EXPORTED = false

--- Pure: what a decision leaves on a photograph — the keywords `plan` converges to and the
-- fields GrMetadata.writeGenreFields records. Genres keep the decision's order (the model's
-- priority), the primary first; NO_GENRE is a primary with no genres and no keyword.
-- @param decision { primary = genre | NO_GENRE | nil, genres = {names} }
-- @return { genres, secondaries = {names}, primary = genre | NO_GENRE | nil }
function Keywords.wanted(decision)
  local primary = decision and decision.primary
  local genres, secondaries, seen = {}, {}, {}
  if primary == Taxonomy.NO_GENRE then
    return { genres = genres, secondaries = secondaries, primary = primary }
  end
  if not Taxonomy.isGenre(primary) then primary = nil end
  if primary then genres[1] = primary; seen[primary] = true end
  for _, g in ipairs((decision and decision.genres) or {}) do
    if Taxonomy.isGenre(g) and not seen[g] then
      seen[g] = true
      genres[#genres + 1] = g
      secondaries[#secondaries + 1] = g
    end
  end
  return { genres = genres, secondaries = secondaries, primary = primary }
end

--- Pure: the decision a photograph's keywords express (`current` as in `plan`), for
-- Update Genre Keywords: its `Genre` keywords, with `primary` (the photograph's field).
-- `secondaries` (the field's order) is kept for the genres still present. A NO_GENRE
-- primary with genre keywords present takes the first of them: no genre and a genre cannot
-- both hold.
-- @return { primary = genre | NO_GENRE | nil, genres = {names} }
function Keywords.held(current, primary, secondaries)
  local present = {}
  for _, k in ipairs(current or {}) do
    if k.branch == Keywords.GENRE and Taxonomy.isGenre(k.name) then present[k.name] = true end
  end
  local genres, seen = {}, {}
  local function take(g)
    if present[g] and not seen[g] then seen[g] = true; genres[#genres + 1] = g end
  end
  for _, g in ipairs(secondaries or {}) do take(g) end
  for _, g in ipairs(Taxonomy.genres) do take(g) end
  if primary == Taxonomy.NO_GENRE and #genres > 0 then primary = genres[1] end
  if primary == '' then primary = nil end
  return { primary = primary, genres = genres }
end

--- Pure: what to change on one photograph.
-- @param current array of { branch = 'Genre' | nil, name, ref } — every keyword on the
--        photo; branch is nil for anything outside the top-level `Genre`
-- @param decision { primary = name|NO_GENRE|nil, genres = {names} } — No genre, or no genres
--        and no primary, means "no genre keywords at all" (No genre / Remove Genre Keywords)
-- @return { add = { {branch, name} }, remove = { ref } }
function Keywords.plan(current, decision)
  local managed = {}
  for _, g in ipairs(Taxonomy.genres) do managed[g] = true end

  local wanted = {}
  for _, g in ipairs(Keywords.wanted(decision).genres) do wanted[g] = true end

  local out = { add = {}, remove = {} }
  local have = {}
  for _, k in ipairs(current or {}) do
    if k.branch == Keywords.GENRE and managed[k.name] then
      if wanted[k.name] and not have[k.name] then have[k.name] = true
      else out.remove[#out.remove + 1] = k.ref end                   -- invariant 1
    end
  end

  -- Taxonomy order keeps the result deterministic.
  for _, g in ipairs(Taxonomy.genres) do
    if wanted[g] and not have[g] then out.add[#out.add + 1] = { Keywords.GENRE, g } end
  end
  return out
end

-- ------------------------------------------------------------ Lightroom-bound

--- Pure: is a keyword (its `path`, names from the root down) the keyword at `prefix` or
-- nested under it?
function Keywords.under(path, prefix)
  if not path or not prefix or #path < #prefix then return false end
  for i, name in ipairs(prefix) do
    if path[i] ~= name then return false end
  end
  return true
end

--- The photo's keywords: each with its name, its `path` from the root, and `branch = 'Genre'`
-- when it is a direct child of the top-level `Genre`.
-- Catalog reads yield, hence LrTasks.pcall (plain pcall fails silently in Lightroom).
function Keywords.currentOf(photo)
  local LrTasks = import 'LrTasks'
  local ok, result = LrTasks.pcall(function()
    local out = {}
    for _, kw in ipairs(photo:getRawMetadata('keywords') or {}) do
      local name = kw:getName()
      local path, node = { name }, kw:getParent()
      -- A keyword tree is never this deep; the cap only guards against a cycle.
      while node and #path < 32 do
        table.insert(path, 1, node:getName())
        node = node:getParent()
      end
      local branch = (#path == 2 and path[1] == Keywords.GENRE) and Keywords.GENRE or nil
      out[#out + 1] = { branch = branch, name = name, path = path, ref = kw }
    end
    return out
  end)
  if not ok then error('reading keywords failed: ' .. tostring(result), 0) end
  return result
end

--- Key of one keyword in the refs table ensureTree returns.
function Keywords.refKey(branch, name) return branch .. '\t' .. name end

--- Inside a write gate: find or create each parent and child ONCE, and return the keyword
-- objects for a later gate to assign. Created keywords are not exported (R5.2); an existing
-- keyword keeps its own setting.
-- Each keyword is looked up exactly once per command: inside Lightroom, a repeated
-- createKeyword(..., returnExisting = true) in the same command returned nil for a keyword
-- that exists (2026-10-05: "photo 3 of 4, createKeyword Genre > Portrait"), so a
-- multi-photo accept failed while single-photo accepts worked.
-- @return refs { [refKey(branch, name)] = keyword }
function Keywords.ensureTree(catalog, adds)
  local parents, refs = {}, {}
  for _, a in ipairs(adds) do
    local branch, name = a[1], a[2]
    local key = Keywords.refKey(branch, name)
    if not refs[key] then
      if not parents[branch] then
        parents[branch] = catalog:createKeyword(branch, {}, EXPORTED, nil, true)
        if not parents[branch] then error(string.format('keyword %s not found or created', branch), 0) end
      end
      refs[key] = catalog:createKeyword(name, {}, EXPORTED, parents[branch], true)
      if not refs[key] then error(string.format('keyword %s > %s not found or created', branch, name), 0) end
    end
  end
  return refs
end

--- Inside a write gate: find or create the keyword at `path` (names from the root), so the
-- Personal keyword exists for the user to apply. An existing keyword is reused unchanged; a
-- new one is not exported. Never assigned by the plugin.
function Keywords.ensurePath(catalog, path)
  local parent
  for i, name in ipairs(path) do
    local kw = catalog:createKeyword(name, {}, EXPORTED, parent, true)
    if not kw then error('keyword ' .. table.concat(path, ' > ', 1, i) .. ' not found or created', 0) end
    parent = kw
  end
  return parent
end

--- Inside a LATER write gate: assign the keyword objects ensureTree returned. No lookups
-- here (see ensureTree).
-- @param note optional function(step): told each SDK call before it is made, so a failure
--        inside Lightroom (which reports only "assertion failed!") can name the call.
function Keywords.assign(photo, plan, refs, note)
  note = note or function() end
  for _, ref in ipairs(plan.remove) do note('removeKeyword'); photo:removeKeyword(ref) end
  for _, a in ipairs(plan.add) do
    local branch, name = a[1], a[2]
    local kw = refs[Keywords.refKey(branch, name)]
    if not kw then error(string.format('keyword %s > %s was not prepared', branch, name), 0) end
    note('addKeyword ' .. branch .. ' > ' .. name)
    photo:addKeyword(kw)
  end
end

return Keywords
