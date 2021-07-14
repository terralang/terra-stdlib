import "std.enum"

local CT = require 'std.constraint'

local M = {}

M.MakeResult = terralib.memoize(function(OkayType, ErrorType)
	local enum Result {
		ok: OkayType,
		err: ErrorType
	}

	return Result
end)

return M
