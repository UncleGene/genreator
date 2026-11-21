--[[
Info.lua — Genreator plugin manifest.

Registers only commands that are implemented, so a menu never advertises something that
does nothing.
]]

-- A divider between menu groups. Lightroom draws '-' as an ordinary item (seen 2026-10-05),
-- so this is a line of box-drawing characters, greyed out by an enabledWhen that is false
-- unless videos are selected; choosing it does nothing (GrMenuNoop.lua).
local DIVIDER = { title = '──────────', file = 'GrMenuNoop.lua', enabledWhen = 'videosSelected' }

return {

  LrSdkVersion        = 10.0,
  LrSdkMinimumVersion = 6.0,

  LrToolkitIdentifier = 'com.genreator.lightroom',
  LrPluginName        = 'Genreator',

  LrPluginInfoUrl     = 'https://github.com/UncleGene/genreator',

  -- Custom metadata fields (ADR-001). Exactly one metadata provider is permitted.
  LrMetadataProvider  = 'GenreatorMetadata.lua',

  -- Menus (2026-10-05). The SDK allows only title / file / enabledWhen per item — no
  -- submenus, no documented separators — but three menus: daily work goes in Library,
  -- set-up / reports / maintenance in File, diagnostics in Help. Daily items follow the
  -- review order (classify; step 1 genres; step 2 primary) and are greyed out without a
  -- selection. Titles stay unique: macOS App Shortcuts bind to the exact title.
  LrLibraryMenuItems = {
    { title = 'Classify Selected Photos', file = 'GrMenuClassify.lua', enabledWhen = 'photosSelected' },
    { title = 'Reclassify Selected Photos', file = 'GrMenuReclassify.lua', enabledWhen = 'photosSelected' },
    { title = 'Pick Photos to Review…', file = 'GrMenuPick.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    { title = 'Remove Genre', file = 'GrMenuRemoveGenre.lua', enabledWhen = 'photosSelected' },
    { title = 'Add Genre…', file = 'GrMenuAddGenre.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    { title = 'Set Primary Genre…', file = 'GrMenuSetPrimary.lua', enabledWhen = 'photosSelected' },
    { title = 'Accept Suggestion', file = 'GrMenuAccept.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    { title = 'Correct Genres…', file = 'GrMenuCorrect.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    -- A rating round is separate from the genres' review (ADR-029).
    { title = 'Suggest Ratings', file = 'GrMenuRate.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    -- The keyword review (ADR-030): suggest, vet in Keywords to Verify, mark verified.
    { title = 'Suggest Keywords', file = 'GrMenuSuggestKeywords.lua', enabledWhen = 'photosSelected' },
    { title = 'Mark Keywords Verified', file = 'GrMenuMarkVerified.lua', enabledWhen = 'photosSelected' },
    { title = 'Re-suggest Keywords', file = 'GrMenuResuggestKeywords.lua', enabledWhen = 'photosSelected' },
  },

  LrExportMenuItems = {
    { title = 'Set Up Review Collections', file = 'GrMenuSetUpCollections.lua' },
    { title = 'Apply Approved Genres…', file = 'GrMenuApplyApproved.lua' },
    { title = 'Apply Keyword Judgements…', file = 'GrMenuApplyJudgements.lua' },
    { title = 'Genre Quality Summary', file = 'GrMenuQualitySummary.lua' },
    { title = 'Export Report (CSV)', file = 'GrMenuExportReport.lua', enabledWhen = 'photosSelected' },
    DIVIDER,
    { title = 'Check Model', file = 'GrMenuCheckModel.lua' },
    DIVIDER,
    { title = 'Re-derive Personal Suggestions', file = 'GrMenuRederive.lua', enabledWhen = 'photosSelected' },
    { title = 'Update Genre Keywords', file = 'GrMenuUpdateKeywords.lua', enabledWhen = 'photosSelected' },
    { title = 'Remove Genre Keywords', file = 'GrMenuRemoveKeywords.lua', enabledWhen = 'photosSelected' },
    { title = 'Clear Plugin Data', file = 'GrMenuClearData.lua', enabledWhen = 'photosSelected' },
  },

  LrHelpMenuItems = {
    { title = 'Show Genreator Diagnostics', file = 'GrMenuDiagnostics.lua' },
  },

  VERSION = { major = 0, minor = 1, revision = 0, build = 1 },
}
