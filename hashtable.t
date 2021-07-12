local A = require 'std.alloc'
local O = require 'std.object' 
local R = require 'std.result'

local CStr = terralib.includec("string.h")
local Cstdio = terralib.includec("stdio.h")

local M = {}

-- Implementation of djb2. Treats all data as a stream of bytes.
terra M.hash_djb2(data: &int8, size: uint): uint
	var hash: uint = 5381

	for i = 0, size do
		hash = ((hash << 5) + hash * 33) + data[i]
	end

	return hash
end

function M.CreateDefaultHashFunction(KeyType)
	if KeyType == rawstring then
		local terra default_string_hash(str: KeyType)
			return M.hash_djb2(str, CStr.strlen(str))
		end
		return default_string_hash
	-- TODO: Add more cases here
	else
		local terra naive_hash(obj: KeyType)
			return M.hash_djb2(obj, sizeof(obj))
		end
		return naive_hash
	end
end

function M.CreateDefaultEqualityFunction(KeyType)
	-- TODO: Need more cases here too
	local terra naive_equal_function(k1: KeyType, k2: KeyType): bool
		return k1 == k2
	end
	return naive_equal_function
end

-- Using error codes instead of strings because it's easier to define the nature of the error since we don't have standardized error types.
M.Errors = {
	-- There was an error allocating memory
	AllocationError = constant(uint, 1),
	-- An error occured because the hash_table is at capacity
	AtCapacity = constant(uint, 2)
}

function M.HashTable(KeyType, ValueType, HashFn, EqFn, Options, Alloc)
	-- Default parameters
	HashFn = HashFn or M.CreateDefaultHashFunction(KeyType)
	EqFn = EqFn or M.CreateDefaultEqualityFunction(KeyType)
	Options = Options or {}
	Alloc = Alloc or A.default_allocator

	-- Constants
	local MetadataHashBitmap = constant(uint8, 127) -- 0b01111111
	local MetadataEmpty = constant(uint8, 128) -- 0b10000000
	local GroupLength = constant(uint, 16)

	-- Determine if this hashtable should operate as a hash set or a hash map
	local IsKeyValue = ValueType ~= nil
	local BucketType = IsKeyValue and struct { key: KeyType, value: ValueType } or struct { key: KeyType }

	local struct HashInformation {
		key: KeyType
		initial_bucket_index: uint
		h1: uint
		h2: uint8
	}

	local struct InsertData {
		-- The old metadata of the bucket before a new item was placed
		old_metadata: uint8
		-- The index where the place occured.
		index: uint
		-- The hash information of the bucket
		hash: HashInformation
	}

	local struct HashTable(O.Object) {
		-- The total number of buckets in the table.
		capacity: uint
		-- The number of items stored in the table
		size: uint
		-- Pointer to free on destruction
		opaque_ptr: &opaque
		-- Array of bytes holding the metadata of the table.
		metadata: &uint8
		-- The backing array of the hashtable.
		buckets: &BucketType
	}

	-- Result types
	local CallocResult = R.MakeResult(tuple(&opaque, &uint8, &BucketType), uint)
	local ProbeResult = R.MakeResult(uint, uint)
	local InsertResult = R.MakeResult(InsertData, uint)

	-- Allocates and initalizes memory for the hashtable. The metadata array is initalized to `MetadataEmpty`. Buckets are not initialized to any value.
	-- Returns a Result containing either a triple or an error code.
	-- The triple consists of an opaque pointer which should be freed, a pointer to the metadata array, and a pointer to the bucket array.
	local terra table_calloc(capacity: uint): CallocResult
		var opaque_ptr = Alloc:alloc_raw(capacity * (sizeof(BucketType) + 1))
		
		if opaque_ptr == nil then
			return CallocResult.err(M.Errors.AllocationError)
		end

		var metadata_array = [&uint8](opaque_ptr)
		var buckets_array = [&BucketType](metadata_array + capacity)

		CStr.memset(metadata_array, MetadataEmpty, capacity)

		return CallocResult.ok{opaque_ptr, metadata_array, buckets_array}
	end

	local terra compute_hash_information(key: KeyType, capacity: uint): HashInformation
		var hash = [ HashFn ](key)

		return HashInformation {
			key = key,
			initial_bucket_index = (hash >> 7) % capacity,
			h1 = hash >> 7,
			h2 = hash and MetadataHashBitmap
		}
	end

	-- Probes the hash_table for the bucket that would contain the key. Returns a result containing either an index or an error code.
	-- If the key exists in the hashtable, then the index returned refers to the bucket containing that key. 
	-- If the key does not exist in the hashtable, then the index returned refers to an empty bucket where the key would be stored.
	local terra linear_probe(hash: HashInformation, metadata_array: &uint8, buckets_array: &BucketType, capacity: uint): ProbeResult
		for virtual_index = hash.initial_bucket_index, capacity + hash.initial_bucket_index do
			var index = virtual_index and (capacity -1)
			var metadata = metadata_array[index]

			if metadata == MetadataEmpty or (metadata == hash.h2 and [EqFn](hash.key, buckets_array[index].key)) then
				return ProbeResult.ok(index)
			end
		end

		return ProbeResult.err(M.Errors.AtCapacity)
	end 

	-- Inserts a bucket into the provided hashtable.
	-- Returns a result containing an InsertData or an error code 
	local terra insert_bucket(bucket: BucketType, metadata_array: &uint8, buckets_array: &BucketType, capacity: uint): InsertResult 
		var hash_info = compute_hash_information(bucket.key, capacity)
		var probe_result = linear_probe(hash_info, metadata_array, buckets_array, capacity)

		if probe_result:is_err() then
			return InsertResult.err(probe_result.err)
		end

		var index = probe_result.ok
		var old_metadata = metadata_array[index]

		metadata_array[index] = hash_info.h2
		buckets_array[index] = bucket

		return InsertResult.ok{old_metadata, index, hash_info}
	end

	local terra find_next_power_of_two(starting: uint, minimum: uint): uint
		while starting < minimum do
			starting = starting * 2
		end
		
		return starting
	end

	terra HashTable:init()
		var initial_capacity = SM.GroupLength
		var calloc_result = table_calloc(initial_capacity)
		
		if calloc_result:is_ok() then
			var opaque_ptr, metadata, buckets = calloc_result.ok
			
			self:_init {
				capacity = initial_capacity,
				size = 0,
				opaque_ptr = opaque_ptr,
				metadata = metadata,
				buckets = buckets
			}
		end
	end

	terra HashTable:destruct()
		[Alloc]:free_raw(self.opaque_ptr)
		CStr.memset(self, 0, sizeof(HashTable)) 
	end

	-- Resizes the hashtable to be at least the size of the requested_capacity. Returns 0 if there was no error. 
	terra HashTable:reserve(requested_capacity: uint): uint
		-- If the requested_capacity is lower than self.capacity, return
		if requested_capacity < self.capacity then
			return 0
		end

		var new_capacity = find_next_power_of_two(self.capacity, requested_capacity) 
		var calloc_result = table_calloc(new_capacity)

		if calloc_result:is_err() then
			return calloc_result.err
		end

		var new_opaque, new_metadata, new_buckets = calloc_result.ok 

		-- Iterate through the old data and rehash existing entries
		for i = 0, self.capacity do
			if self.metadata[i] ~= MetadataEmpty then
				var bucket = self.buckets[i]
				var insert_result = insert_bucket(bucket, new_metadata, new_buckets, new_capacity)

				if insert_result:is_err() then
					[Alloc]:free_raw(new_opaque)
					return inset_result.err
				end
			end
		end

		[Alloc]:free_raw(self.opaque_ptr)
		self.opaque_ptr = new_opaque
		self.metadata = new_metadata
		self.buckets = new_buckets
		self.capacity = new_capacity

		return 0
	end

	terra HashTable:has(key: KeyType): bool
		var hash_information = compute_hash_information(key, self.capacity)
		var probe_result = linear_probe(self, key, hash_information)

		if probe_result:is_ok() and self.metadata[probe_result.ok] ~= MetadataEmpty then
			return true
		else
			return false
		end
	end

	local InsertBody = macro(function(self, bucket)
		return quote
			if [self].size == [self].capacity then
				[self]:resize([self].capacity * 2)
			end
			
			var insert_result = insert_bucket([bucket], [self].metadata, [self].buckets, [self].capacity)

			if insert_result:is_err() then
				return insert_result.err
			end

			if insert_result.ok.old_metadata ~= MetadataEmpty then
				self.size = self.size + 1
			end 

			return 0
		end
	end)

	if IsKeyValue then
		terra HashTable:insert(key: KeyType, value: ValueType): uint
			return InsertBody(self, BucketType { key = key, value = value })
		end
	else
		terra HashTable:insert(key: KeyType): uint
			return InsertBody(self, { key = key })
		end
	end

	local DebugTypeInformation = "{ key: " .. tostring(KeyType) .. ( IsKeyValue and ", value: " .. tostring(ValueType)) .. " }"
	local DebugHeaderString = "HashTable " .. DebugTypeInformation .. " Size: %u; Capacity: %u; OpaquePtr: %p\n"

	-- Prints a debug view of the metadata array to stdout
	terra HashTable:debug_metadata_repr()
		Cstdio.printf(DebugHeaderString, self.size, self.capacity, self.opaque_ptr)
		for i = 0, self.capacity do
			Cstdio.printf("[%u]\t%p - 0x%02X\n", i, self.metadata + i, self.metadata[i])
		end
	end

	-- Prints a debug view of the table to stdout.
	terra HashTable:debug_full_repr()
		Cstdio.printf(DebugHeaderString, self.size, self.capacity, self.opaque_ptr)
		for i = 0, self.capacity do
			Cstdio.printf("[%u]\tMetadata: %p = 0x%02X\tBucket: %p = ", i, self.metadata + i, self.metadata[i], self.buckets + i)

			if self.metadata[i] == 128 then
				Cstdio.printf("Empty\n", self.buckets + i)
			elseif self.buckets + i == nil then
				Cstdio.printf("NULLPTR\n")
			else
				-- TODO: this won't work all the time, refactor to handle all types later
				if IsKeyValue then
					Cstdio.printf("{ key = %s, value = %s }\n", self.buckets[i].key, self.buckets[i].value)
				else
					Cstdio.printf("%s", self.buckets[i].key)
				end
			end
		end
	end

	return HashTable
end


return M
