local luahttpadapter = require('./runtime/lua-http-adapter')
local sigv4 = require('./runtime/sigv4')
local sqs = require('./client')
local http = require('./runtime/http')

local client = sqs.New({
    Region   = 'us-east-1',
    HTTPClient = luahttpadapter.HTTPClient.New({}) as http.Client,
    Credentials = sigv4.Credentials.New{
        AKID = os.getenv('AWS_ACCESS_KEY_ID'),
        Secret = os.getenv('AWS_SECRET_ACCESS_KEY'), 
        SessionToken = os.getenv('AWS_SESSION_TOKEN'),
    },
})

local createQueueOutput = client:CreateQueue({
    QueueName = 'que2',
})

local listQueuesOutput = client:ListQueues({})

print('queues:')
for _,q in ipairs(listQueuesOutput.QueueUrls) do
    print(q)
end
