local HT = require 'std.hashtable'
local O = require 'std.object'

local Cio = terralib.includec("stdio.h")

describe("Hashtable without values", function()
	local StringHashSet = HT.HashTable(rawstring)

	it("should insert and check the existence of values", terra()
		var hash_set = O.new(StringHashSet)

		var expected = {"STRONK", "Identity"}

		assert.equal(0, hash_set:insert(expected._0))
		assert.equal(0, hash_set:insert(expected._1))

		assert.is_true(hash_set:has(expected._0))
		assert.is_true(hash_set:has(expected._1))
		assert.equal(2, hash_set.size)
	end)

	it("should resize its capacity without changing items", terra()
		var hash_set = O.new(StringHashSet)

		hash_set:insert("Cutiemarks")
		hash_set:insert("and the")
		hash_set:insert("things that")
		hash_set:insert("bind us")

		Cio.printf("Before resize:\n")
		hash_set:debug_full_repr()

		assert.equal(0, hash_set:reserve(31))

		Cio.printf("After resize:\n")
		hash_set:debug_full_repr()
		assert.equal(4, hash_set.size)
		assert.is_true(hash_set.capacity >= 31)
	end)
end)

describe("Implementation.DenseHashTable HashMap", function()
	local StringHashMap = HT.HashTable(rawstring, rawstring)

	it("should insert and check the existence of values", terra()
		var hash_map = O.new(StringHashMap)

		assert.equal(0, hash_map:insert("I'm living proof", "that the worst can be beat"))
		assert.equal(0, hash_map:insert("if ya pull yourself together", "you can get on your feet"))
		assert.equal(0, hash_map:insert("living proof that", "the strength you will need"))
		assert.equal(0, hash_map:insert("has been in you forever", "but to get it, you'll bleed"))

		assert.is_true(hash_map:has("I'm living proof"))
		assert.is_true(hash_map:has("if ya pull yourself together"))
		assert.is_true(hash_map:has("living proof that"))
		assert.is_true(hash_map:has("has been in you forever"))
		assert.equal(4, hash_map.size)
	end)
end)
