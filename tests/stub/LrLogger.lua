-- Stub of LrLogger: swallows output so GrLog can be exercised without side effects.
local M = setmetatable({}, {
  __call = function()
    local logger = { _lines = {} }
    function logger:enable() end
    local function noop(self, msg)
      self._lines[#self._lines + 1] = tostring(msg)
    end
    logger.error, logger.warn, logger.info, logger.debug = noop, noop, noop, noop
    logger.trace = noop
    return logger
  end,
})
return M
