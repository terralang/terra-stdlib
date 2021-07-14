local R = require "std.result"

describe("std.result", function()
	local IntResult = R.MakeResult(int, int) 

	it("can be instantiated in both okay and error alternatives", terra()
		var okay = IntResult.ok(42)
		var err = IntResult.err(76)
	end)
end)
