local json = require('./runtime/json')
local http = require('./runtime/http')
local sigv4 = require('./runtime/sigv4')

local Client = {}

local function _do(client, input, target)
    local req = http.Request.New()

    local endpoint = 'https://sqs.'..client._config.Region..'.amazonaws.com'
    req.URL = endpoint
    req.Host = 'sqs.'..client._config.Region..'.amazonaws.com'

    req.Method = 'POST'
    req.Header:Set("Content-Type", "application/x-amz-json-1.0")
    req.Header:Set("X-Amz-Target", target)

    -- https://github.com/rxi/json.lua/issues/23
    -- empty tables encode as [] which awsJson will not accept, so do it ourselves instead
    if #input == 0 then
        req.Body = '{}'
    else
        req.Body = json.encode(input)
    end

    sigv4.Sign(req, client._config.Credentials, "sqs", client._config.Region)

    local resp = client._config.HTTPClient:Do(req)
    return json.decode(resp.Body), nil
end

function Client.New(config)
    return setmetatable({
        _config = {
            Region      = config.Region,
            Credentials = config.Credentials,
            HTTPClient  = config.HTTPClient,
        },
    }, { __index = Client })
end

function Client:AddPermission(input)
    return _do(self, input, "AmazonSQS.AddPermission")
end

function Client:CancelMessageMoveTask(input)
    return _do(self, input, "AmazonSQS.CancelMessageMoveTask")
end

function Client:ChangeMessageVisibility(input)
    return _do(self, input, "AmazonSQS.ChangeMessageVisibility")
end

function Client:ChangeMessageVisibilityBatch(input)
    return _do(self, input, "AmazonSQS.ChangeMessageVisibilityBatch")
end

function Client:CreateQueue(input)
    return _do(self, input, "AmazonSQS.CreateQueue")
end

function Client:DeleteMessage(input)
    return _do(self, input, "AmazonSQS.DeleteMessage")
end

function Client:DeleteMessageBatch(input)
    return _do(self, input, "AmazonSQS.DeleteMessageBatch")
end

function Client:DeleteQueue(input)
    return _do(self, input, "AmazonSQS.DeleteQueue")
end

function Client:GetQueueAttributes(input)
    return _do(self, input, "AmazonSQS.GetQueueAttributes")
end

function Client:GetQueueUrl(input)
    return _do(self, input, "AmazonSQS.GetQueueUrl")
end

function Client:ListDeadLetterSourceQueues(input)
    return _do(self, input, "AmazonSQS.ListDeadLetterSourceQueues")
end

function Client:ListMessageMoveTasks(input)
    return _do(self, input, "AmazonSQS.ListMessageMoveTasks")
end

function Client:ListQueues(input)
    return _do(self, input, "AmazonSQS.ListQueues")
end

function Client:ListQueueTags(input)
    return _do(self, input, "AmazonSQS.ListQueueTags")
end

function Client:PurgeQueue(input)
    return _do(self, input, "AmazonSQS.PurgeQueue")
end

function Client:ReceiveMessage(input)
    return _do(self, input, "AmazonSQS.ReceiveMessage")
end

function Client:RemovePermission(input)
    return _do(self, input, "AmazonSQS.RemovePermission")
end

function Client:SendMessage(input)
    return _do(self, input, "AmazonSQS.SendMessage")
end

function Client:SendMessageBatch(input)
    return _do(self, input, "AmazonSQS.SendMessageBatch")
end

function Client:SetQueueAttributes(input)
    return _do(self, input, "AmazonSQS.SetQueueAttributes")
end

function Client:StartMessageMoveTask(input)
    return _do(self, input, "AmazonSQS.StartMessageMoveTask")
end

function Client:TagQueue(input)
    return _do(self, input, "AmazonSQS.TagQueue")
end

function Client:UntagQueue(input)
    return _do(self, input, "AmazonSQS.UntagQueue")
end

return Client
