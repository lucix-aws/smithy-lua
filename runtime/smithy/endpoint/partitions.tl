-- smithy-lua runtime: partition data
-- This file is large static data; keep as .lua and provide a .tl declaration.

local record partitions_mod
    record Partition
        id: string
        regionRegex: string
        regions: {string:any}
        outputs: {string:any}
        dnsSuffix: string
        dualStackDnsSuffix: string
        supportsFIPS: boolean
        supportsDualStack: boolean
        implicitGlobalRegion: string
        name: string
    end

    get_partition: function(region: string): Partition
end

-- Partition data
local partition_list: {partitions_mod.Partition} = {
    {
        id = "aws",
        regionRegex = "^(us|eu|ap|sa|ca|me|af|il)\\-\\w+\\-\\d+$",
        regions = { ["us-east-1"] = {}, ["us-west-2"] = {}, ["eu-west-1"] = {}, ["ap-northeast-1"] = {} },
        outputs = { dnsSuffix = "amazonaws.com", dualStackDnsSuffix = "api.aws", name = "aws", supportsDualStack = true, supportsFIPS = true, implicitGlobalRegion = "us-east-1" },
        dnsSuffix = "amazonaws.com",
        dualStackDnsSuffix = "api.aws",
        supportsFIPS = true,
        supportsDualStack = true,
        implicitGlobalRegion = "us-east-1",
        name = "aws",
    },
    {
        id = "aws-cn",
        regionRegex = "^cn\\-\\w+\\-\\d+$",
        regions = { ["cn-north-1"] = {}, ["cn-northwest-1"] = {} },
        outputs = { dnsSuffix = "amazonaws.com.cn", dualStackDnsSuffix = "api.amazonwebservices.com.cn", name = "aws-cn", supportsDualStack = true, supportsFIPS = true, implicitGlobalRegion = "cn-northwest-1" },
        dnsSuffix = "amazonaws.com.cn",
        dualStackDnsSuffix = "api.amazonwebservices.com.cn",
        supportsFIPS = true,
        supportsDualStack = true,
        implicitGlobalRegion = "cn-northwest-1",
        name = "aws-cn",
    },
    {
        id = "aws-us-gov",
        regionRegex = "^us\\-gov\\-\\w+\\-\\d+$",
        regions = { ["us-gov-west-1"] = {}, ["us-gov-east-1"] = {} },
        outputs = { dnsSuffix = "amazonaws.com", dualStackDnsSuffix = "api.aws", name = "aws-us-gov", supportsDualStack = true, supportsFIPS = true, implicitGlobalRegion = "us-gov-west-1" },
        dnsSuffix = "amazonaws.com",
        dualStackDnsSuffix = "api.aws",
        supportsFIPS = true,
        supportsDualStack = true,
        implicitGlobalRegion = "us-gov-west-1",
        name = "aws-us-gov",
    },
    {
        id = "aws-iso",
        regionRegex = "^us\\-iso\\-\\w+\\-\\d+$",
        regions = { ["us-iso-east-1"] = {}, ["us-iso-west-1"] = {} },
        outputs = { dnsSuffix = "c2s.ic.gov", dualStackDnsSuffix = "c2s.ic.gov", name = "aws-iso", supportsDualStack = false, supportsFIPS = true, implicitGlobalRegion = "us-iso-east-1" },
        dnsSuffix = "c2s.ic.gov",
        dualStackDnsSuffix = "c2s.ic.gov",
        supportsFIPS = true,
        supportsDualStack = false,
        implicitGlobalRegion = "us-iso-east-1",
        name = "aws-iso",
    },
    {
        id = "aws-iso-b",
        regionRegex = "^us\\-isob\\-\\w+\\-\\d+$",
        regions = { ["us-isob-east-1"] = {} },
        outputs = { dnsSuffix = "sc2s.sgov.gov", dualStackDnsSuffix = "sc2s.sgov.gov", name = "aws-iso-b", supportsDualStack = false, supportsFIPS = true, implicitGlobalRegion = "us-isob-east-1" },
        dnsSuffix = "sc2s.sgov.gov",
        dualStackDnsSuffix = "sc2s.sgov.gov",
        supportsFIPS = true,
        supportsDualStack = false,
        implicitGlobalRegion = "us-isob-east-1",
        name = "aws-iso-b",
    },
}

function partitions_mod.get_partition(region: string): partitions_mod.Partition
    -- Check explicit regions first
    for _, p in ipairs(partition_list) do
        if (p.regions as {string:any})[region] then
            return p
        end
    end
    -- Check regex patterns
    for _, p in ipairs(partition_list) do
        if region:match(p.regionRegex) then
            return p
        end
    end
    -- Default to aws
    return partition_list[1]
end

return partitions_mod
