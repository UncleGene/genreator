-- Stub of LrProgressScope. Records captions and honours a scripted cancel point.
local M = {}

M._cancelAfter = nil   -- cancel once this many setPortionComplete calls have happened
M._last = nil

function M._reset()
  M._cancelAfter = nil
  M._last = nil
end

setmetatable(M, {
  __call = function(_, params)
    local scope = {
      _params = params,
      _captions = {},
      _portionCalls = 0,
      _cancelable = false,
      _canceled = false,
    }
    function scope:setCancelable(v) self._cancelable = v end
    function scope:setCaption(c) self._captions[#self._captions + 1] = c end
    function scope:setPortionComplete(done, total)
      self._portionCalls = self._portionCalls + 1
      self._done, self._total = done, total
      if M._cancelAfter and self._portionCalls >= M._cancelAfter then
        self._canceled = true
      end
    end
    function scope:isCanceled() return self._canceled end
    function scope:done() self._isDone = true end
    M._last = scope
    return scope
  end,
})

return M
