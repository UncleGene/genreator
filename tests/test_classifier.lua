--[[
Tests for GrClassifier's pure helpers: chunking and selection filtering.

The orchestrator's SDK-bound body (progress scopes, write-access gates, dialogs) is
verified by hand in Lightroom per the checklist in docs/development.md.
]]

local t = require 'harness'
local Classifier = require 'GrClassifier'
local Photo = require 'photo'

t.suite('GrClassifier — chunking')

t.eq(Classifier.chunk({ 1, 2, 3, 4, 5 }, 2), { { 1, 2 }, { 3, 4 }, { 5 } },
     'splits into chunks with a short final chunk')
t.eq(Classifier.chunk({ 1, 2, 3, 4 }, 2), { { 1, 2 }, { 3, 4 } },
     'splits evenly when the length divides')
t.eq(Classifier.chunk({ 1 }, 10), { { 1 } }, 'a single item makes one chunk')
t.eq(Classifier.chunk({}, 10), {}, 'an empty list makes no chunks')
t.eq(Classifier.chunk({ 1, 2, 3 }, 1), { { 1 }, { 2 }, { 3 } },
     'a chunk size of one makes one chunk each')
t.eq(Classifier.chunk({ 1, 2, 3 }, 99), { { 1, 2, 3 } },
     'an oversized chunk size makes one chunk')

-- No item may be lost or duplicated, at any chunk size
for size = 1, 7 do
  local list = {}
  for i = 1, 20 do list[i] = i end
  local chunks = Classifier.chunk(list, size)
  local flat = {}
  for _, c in ipairs(chunks) do
    for _, v in ipairs(c) do flat[#flat + 1] = v end
  end
  t.eq(flat, list, 'chunking preserves every item in order at size ' .. size)
end

t.suite('GrClassifier — selection filtering')

local function info(spec)
  return {
    photo = Photo.new {},
    isVideo = spec.isVideo or false,
    isMissing = spec.isMissing or false,
    isClassified = spec.isClassified or false,
  }
end

local infos = {
  info {},                        -- 1 plain, eligible
  info { isVideo = true },        -- 2 video
  info { isMissing = true },      -- 3 missing original
  info { isClassified = true },   -- 4 already classified
  info {},                        -- 5 plain, eligible
}

local keep, skipped = Classifier.filterSelection(infos, { reclassify = false })

t.eq(#keep, 2, 'keeps only the two eligible photographs')
t.eq(skipped.video, 1, 'counts the skipped video')
t.eq(skipped.missing, 1, 'counts the missing original')
t.eq(skipped.alreadyClassified, 1, 'counts the already-classified photograph (R6.5)')
t.eq(keep[1], infos[1].photo, 'keeps the first eligible photograph')
t.eq(keep[2], infos[5].photo, 'keeps the last eligible photograph')

-- Reclassify picks up already-classified photographs, but still never video or missing
local reKeep, reSkipped = Classifier.filterSelection(infos, { reclassify = true })
t.eq(#reKeep, 3, 'reclassify includes the already-classified photograph')
t.eq(reSkipped.alreadyClassified, 0, 'reclassify skips nothing for being classified')
t.eq(reSkipped.video, 1, 'reclassify still skips video — genre does not apply')
t.eq(reSkipped.missing, 1, 'reclassify still skips missing originals')

-- Edge cases
local emptyKeep, emptySkipped = Classifier.filterSelection({}, {})
t.eq(#emptyKeep, 0, 'an empty selection keeps nothing')
t.eq(emptySkipped.video, 0, 'an empty selection skips nothing')

t.eq(#Classifier.filterSelection(infos, nil), 2,
     'a nil options table behaves like reclassify = false')

-- A video that is also already classified must be counted once, as video
local doubled = { info { isVideo = true, isClassified = true } }
local _, doubleSkipped = Classifier.filterSelection(doubled, {})
t.eq(doubleSkipped.video, 1, 'video takes precedence in skip counting')
t.eq(doubleSkipped.alreadyClassified, 0, 'the same photo is not counted twice')

-- All-ineligible selection
local noneEligible = { info { isVideo = true }, info { isMissing = true } }
local noneKeep = Classifier.filterSelection(noneEligible, {})
t.eq(#noneKeep, 0, 'a fully ineligible selection keeps nothing')

return t
