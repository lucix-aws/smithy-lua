-- Type-check test: S3 list buckets

local s3 = require("s3.client")

local client = s3.new({ region = "us-east-1" })
local op = client:listBuckets({})
local result, err = op:await()
