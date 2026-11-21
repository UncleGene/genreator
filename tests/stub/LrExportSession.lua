-- Stub of LrExportSession. Records the settings it was constructed with so tests can
-- assert the privacy-critical export flags, and yields scripted renditions.
local M = {}

M._lastParams = nil
M._scriptedRenditions = nil   -- array of { photo, success, path }

function M._reset()
  M._lastParams = nil
  M._scriptedRenditions = nil
end

setmetatable(M, {
  __call = function(_, params)
    M._lastParams = params
    local session = {}

    -- Both doExportOn*Task and renditions() start rendering; Lightroom refuses a second
    -- start with "AgExportSession:startRendering: can not call twice on same session".
    local started = false
    local function start()
      if started then
        error('AgExportSession:startRendering: can not call twice on same session', 3)
      end
      started = true
    end

    function session:doExportOnNewTask() start() end

    function session:renditions()
      start()
      -- A real session yields renditions only for its own photosToExport, so filter the
      -- scripted list by this session's photo set. Without this, a chunked run would
      -- see every photo once per chunk.
      local wanted = {}
      for _, p in ipairs(params.photosToExport or {}) do wanted[p] = true end

      local scripted = {}
      for _, s in ipairs(M._scriptedRenditions or {}) do
        if wanted[s.photo] then scripted[#scripted + 1] = s end
      end

      local i = 0
      return function()
        i = i + 1
        local s = scripted[i]
        if not s then return nil end
        -- The SDK yields (index, rendition); taking only the first value gets a number.
        return i, {
          photo = s.photo,
          destinationPath = s.path,
          waitForRender = function()
            if s.success == false then return false, s.message or 'render failed' end
            return true, s.path
          end,
        }
      end
    end

    return session
  end,
})

return M
