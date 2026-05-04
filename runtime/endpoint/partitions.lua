-- AWS partition data for endpoint resolution.
-- Maps regions to partitions and provides partition metadata.

local M = {}

M.partitions = {
    {
        id = "aws",
        regionRegex = "^(us|eu|ap|sa|ca|me|af|il)%-[a-z]+%-[0-9]+$",
        regions = {
            ["af-south-1"] = {},
            ["ap-east-1"] = {},
            ["ap-northeast-1"] = {},
            ["ap-northeast-2"] = {},
            ["ap-northeast-3"] = {},
            ["ap-south-1"] = {},
            ["ap-south-2"] = {},
            ["ap-southeast-1"] = {},
            ["ap-southeast-2"] = {},
            ["ap-southeast-3"] = {},
            ["ap-southeast-4"] = {},
            ["ap-southeast-5"] = {},
            ["ca-central-1"] = {},
            ["ca-west-1"] = {},
            ["eu-central-1"] = {},
            ["eu-central-2"] = {},
            ["eu-north-1"] = {},
            ["eu-south-1"] = {},
            ["eu-south-2"] = {},
            ["eu-west-1"] = {},
            ["eu-west-2"] = {},
            ["eu-west-3"] = {},
            ["il-central-1"] = {},
            ["me-central-1"] = {},
            ["me-south-1"] = {},
            ["sa-east-1"] = {},
            ["us-east-1"] = {},
            ["us-east-2"] = {},
            ["us-west-1"] = {},
            ["us-west-2"] = {},
        },
        outputs = {
            name = "aws",
            dnsSuffix = "amazonaws.com",
            dualStackDnsSuffix = "api.aws",
            supportsFIPS = true,
            supportsDualStack = true,
            implicitGlobalRegion = "us-east-1",
        },
    },
    {
        id = "aws-us-gov",
        regionRegex = "^us%-gov%-[a-z]+%-[0-9]+$",
        regions = {
            ["us-gov-east-1"] = {},
            ["us-gov-west-1"] = {},
        },
        outputs = {
            name = "aws-us-gov",
            dnsSuffix = "amazonaws.com",
            dualStackDnsSuffix = "api.aws",
            supportsFIPS = true,
            supportsDualStack = true,
            implicitGlobalRegion = "us-gov-west-1",
        },
    },
    {
        id = "aws-cn",
        regionRegex = "^cn%-[a-z]+%-[0-9]+$",
        regions = {
            ["cn-north-1"] = {},
            ["cn-northwest-1"] = {},
        },
        outputs = {
            name = "aws-cn",
            dnsSuffix = "amazonaws.com.cn",
            dualStackDnsSuffix = "api.amazonwebservices.com.cn",
            supportsFIPS = true,
            supportsDualStack = true,
            implicitGlobalRegion = "cn-northwest-1",
        },
    },
    {
        id = "aws-iso",
        regionRegex = "^us%-iso%-[a-z]+%-[0-9]+$",
        regions = {
            ["us-iso-east-1"] = {},
            ["us-iso-west-1"] = {},
        },
        outputs = {
            name = "aws-iso",
            dnsSuffix = "c2s.ic.gov",
            dualStackDnsSuffix = "c2s.ic.gov",
            supportsFIPS = true,
            supportsDualStack = false,
            implicitGlobalRegion = "us-iso-east-1",
        },
    },
    {
        id = "aws-iso-b",
        regionRegex = "^us%-isob%-[a-z]+%-[0-9]+$",
        regions = {
            ["us-isob-east-1"] = {},
        },
        outputs = {
            name = "aws-iso-b",
            dnsSuffix = "sc2s.sgov.gov",
            dualStackDnsSuffix = "sc2s.sgov.gov",
            supportsFIPS = true,
            supportsDualStack = false,
            implicitGlobalRegion = "us-isob-east-1",
        },
    },
    {
        id = "aws-iso-e",
        regionRegex = "^eu%-isoe%-[a-z]+%-[0-9]+$",
        regions = {},
        outputs = {
            name = "aws-iso-e",
            dnsSuffix = "cloud.adc-e.uk",
            dualStackDnsSuffix = "cloud.adc-e.uk",
            supportsFIPS = true,
            supportsDualStack = false,
            implicitGlobalRegion = "eu-isoe-west-1",
        },
    },
    {
        id = "aws-iso-f",
        regionRegex = "^us%-isof%-[a-z]+%-[0-9]+$",
        regions = {},
        outputs = {
            name = "aws-iso-f",
            dnsSuffix = "csp.hci.ic.gov",
            dualStackDnsSuffix = "csp.hci.ic.gov",
            supportsFIPS = true,
            supportsDualStack = false,
            implicitGlobalRegion = "us-isof-south-1",
        },
    },
}

--- Look up the partition for a given region.
--- @param region string
--- @return table|nil: partition outputs or nil
function M.get_partition(region)
    -- First: exact match in any partition's region list
    for _, p in ipairs(M.partitions) do
        if p.regions[region] then
            return p.outputs
        end
    end
    -- Second: regex match
    for _, p in ipairs(M.partitions) do
        if region:match(p.regionRegex) then
            return p.outputs
        end
    end
    -- Default to aws partition for unknown regions
    return M.partitions[1].outputs
end

return M
