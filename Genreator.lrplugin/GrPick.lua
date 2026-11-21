--[[
GrPick — choose which photographs to review next (temporary, Pick Photos to Review…).

From a random sample of about 5 × N unclassified photographs, at most 500 unless N is larger
(`sampleSize`; GrClassifier draws it), all scored by the model, pick N. The criteria are fixed
per plugin version (`Pick.VERSION`), so picks made under one version can be told apart from
another's.

pick-v3, one rule for the whole pick: **equal shares per suggested primary genre**, No genre
included. Common primaries are kept almost as suggested (Street, Landscape 98% in the
decisions of 2026-10-29); the rare ones are where the model is most often wrong (Architecture
37%, Object 30% of picks) and where the training data is thinnest. So the picks go round the
suggested primaries in turn, rarest in the sample first, one photograph at a time; a primary
with too few photographs drops out and the others share the rest.

Within one primary, the photographs on the model's edges come first, most signals first, ties
in random order. The signals, one point each (unchanged from pick-v2):

  no-genre   the no-genre score is between 0.2 and 0.8 — the model's weakest answer
  close      the top two primary scores are within 0.15 of each other — a coin-flip primary
  cut-off    some genre's "applies" score is within ±30% of its cut-off — an extra or a
             missing genre

There is no random control half (pick-v2 had one). Each pick records how common its primary
was in the sample, so a measure of the model over picks can be weighted back to the sample:
a pick's weight is its group's size over the picks taken from that group. Personal plays no
part in the pick.

The model's numbers are used here only, while picking; they are never stored (ADR-004). What
is stored is the reason (`pickReason`): `pick-v3:<signals>:<group size>/<sample size>`, e.g.
`pick-v3:close,cut-off:6/500`, `pick-v3:none:212/500`.

Pure module: no Lr* dependency.
]]

local Pick = {}

Pick.VERSION = 'pick-v3'
Pick.SAMPLE_FACTOR = 5
Pick.SAMPLE_CAP = 500
Pick.NO_GENRE_EDGE = { 0.2, 0.8 }
Pick.CLOSE_PRIMARY = 0.15
Pick.CUTOFF_BAND = 0.3

--- Pure: the signals one model answer hits (GrModel.parseResponse's per-photo result).
-- @return array of signal names, in a fixed order
function Pick.signals(result)
  local out = {}
  local p = result and result.noGenreProbability
  if type(p) == 'number' and p >= Pick.NO_GENRE_EDGE[1] and p <= Pick.NO_GENRE_EDGE[2] then
    out[#out + 1] = 'no-genre'
  end
  local ranked = (result and result.ranked) or {}
  -- The model lists genres by primary score, but the top two are taken by value regardless.
  local scores = {}
  for _, r in ipairs(ranked) do
    if type(r.primaryProbability) == 'number' then scores[#scores + 1] = r.primaryProbability end
  end
  table.sort(scores, function(x, y) return x > y end)
  if #scores >= 2 and scores[1] - scores[2] <= Pick.CLOSE_PRIMARY then
    out[#out + 1] = 'close'
  end
  for _, r in ipairs(ranked) do
    if type(r.applicability) == 'number' and type(r.cutoff) == 'number' and r.cutoff > 0
       and math.abs(r.applicability - r.cutoff) <= Pick.CUTOFF_BAND * r.cutoff then
      out[#out + 1] = 'cut-off'
      break
    end
  end
  return out
end

--- Pure: the stored reason for a pick: its signals, and how many of the sample shared its
-- suggested primary.
function Pick.reason(signals, groupSize, sampleSize)
  return string.format('%s:%s:%d/%d', Pick.VERSION, #signals > 0 and table.concat(signals, ',') or 'none',
                       groupSize, sampleSize)
end

--- Pure: shuffle a copy of `list` with `random(n)` -> 1..n.
function Pick.shuffled(list, random)
  local out = {}
  for i, v in ipairs(list) do out[i] = v end
  for i = #out, 2, -1 do
    local j = random(i)
    out[i], out[j] = out[j], out[i]
  end
  return out
end

--- Pure: how many photographs to score for a pick of `n`: SAMPLE_FACTOR × n, capped at
-- SAMPLE_CAP, never fewer than n (scoring takes about as long per photograph as classifying).
function Pick.sampleSize(n)
  return math.min(n * Pick.SAMPLE_FACTOR, math.max(Pick.SAMPLE_CAP, n))
end

--- Pure: choose `n` of `candidates` ({ key, result, group }), `group` being the suggested
-- primary: equal shares per group, rarest first, the most signals first within a group.
-- @return array of { key, result, group, reason }, in the order picked
function Pick.choose(candidates, n, random)
  n = math.min(n, #candidates)
  local groups, byName = {}, {}
  for i, c in ipairs(Pick.shuffled(candidates, random)) do
    local name = c.group or ''
    local g = byName[name]
    if not g then
      g = { name = name, items = {} }
      byName[name] = g
      groups[#groups + 1] = g
    end
    g.items[#g.items + 1] = { c = c, signals = Pick.signals(c.result), order = i }
  end
  for _, g in ipairs(groups) do
    table.sort(g.items, function(x, y)
      if #x.signals ~= #y.signals then return #x.signals > #y.signals end
      return x.order < y.order
    end)
  end
  -- Rarest first, so when n does not divide evenly the rare ones get the extra turn.
  table.sort(groups, function(x, y)
    if #x.items ~= #y.items then return #x.items < #y.items end
    return x.name < y.name
  end)
  local out, round = {}, 1
  while #out < n do
    for _, g in ipairs(groups) do
      local it = g.items[round]
      if it and #out < n then
        out[#out + 1] = { key = it.c.key, result = it.c.result, group = it.c.group,
                          reason = Pick.reason(it.signals, #g.items, #candidates) }
      end
    end
    round = round + 1
  end
  return out
end

return Pick
