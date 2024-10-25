local http = require('./runtime/http')
local sigv4 = require('./runtime/sigv4')

local record module
    record GetQueueAttributesOutput
        Attributes: {string: string}
    end
    record CancelMessageMoveTaskOutput
        ApproximateNumberOfMessagesMoved: number
    end
    record Message
        MessageId: string
        ReceiptHandle: string
        MD5OfBody: string
        Body: string
        Attributes: {string: string}
        MD5OfMessageAttributes: string
        MessageAttributes: {string: MessageAttributeValue}
    end
    record DeleteMessageBatchOutput
        Successful: {DeleteMessageBatchResultEntry}
        Failed: {BatchResultErrorEntry}
    end
    record DeleteQueueOutput
    end
    record ListQueuesOutput
        QueueUrls: {string}
        NextToken: string
    end
    record ListQueueTagsInput
        QueueUrl: string
    end
    record UntagQueueInput
        QueueUrl: string
        TagKeys: {string}
    end
    record DeleteMessageBatchResultEntry
        Id: string
    end
    record CreateQueueInput
        QueueName: string
        Attributes: {string: string}
        tags: {string: string}
    end
    record TagQueueInput
        QueueUrl: string
        Tags: {string: string}
    end
    record ChangeMessageVisibilityOutput
    end
    record UntagQueueOutput
    end
    record TagQueueOutput
    end
    record GetQueueUrlInput
        QueueName: string
        QueueOwnerAWSAccountId: string
    end
    record SetQueueAttributesInput
        QueueUrl: string
        Attributes: {string: string}
    end
    record StartMessageMoveTaskOutput
        TaskHandle: string
    end
    record ListDeadLetterSourceQueuesOutput
        queueUrls: {string}
        NextToken: string
    end
    record ListQueueTagsOutput
        Tags: {string: string}
    end
    record DeleteMessageInput
        QueueUrl: string
        ReceiptHandle: string
    end
    record ListQueuesInput
        QueueNamePrefix: string
        NextToken: string
        MaxResults: number
    end
    record SetQueueAttributesOutput
    end
    record ListMessageMoveTasksResultEntry
        TaskHandle: string
        Status: string
        SourceArn: string
        DestinationArn: string
        MaxNumberOfMessagesPerSecond: number
        ApproximateNumberOfMessagesMoved: number
        ApproximateNumberOfMessagesToMove: number
        FailureReason: string
        StartedTimestamp: number
    end
    record StartMessageMoveTaskInput
        SourceArn: string
        DestinationArn: string
        MaxNumberOfMessagesPerSecond: number
    end
    record ChangeMessageVisibilityBatchResultEntry
        Id: string
    end
    record PurgeQueueOutput
    end
    record DeleteMessageOutput
    end
    record SendMessageBatchRequestEntry
        Id: string
        MessageBody: string
        DelaySeconds: number
        MessageAttributes: {string: MessageAttributeValue}
        MessageSystemAttributes: {string: MessageSystemAttributeValue}
        MessageDeduplicationId: string
        MessageGroupId: string
    end
    record ChangeMessageVisibilityBatchRequestEntry
        Id: string
        ReceiptHandle: string
        VisibilityTimeout: number
    end
    record CreateQueueOutput
        QueueUrl: string
    end
    record ListMessageMoveTasksOutput
        Results: {ListMessageMoveTasksResultEntry}
    end
    record CancelMessageMoveTaskInput
        TaskHandle: string
    end
    record DeleteMessageBatchInput
        QueueUrl: string
        Entries: {DeleteMessageBatchRequestEntry}
    end
    record PurgeQueueInput
        QueueUrl: string
    end
    record SendMessageOutput
        MD5OfMessageBody: string
        MD5OfMessageAttributes: string
        MD5OfMessageSystemAttributes: string
        MessageId: string
        SequenceNumber: string
    end
    record ListMessageMoveTasksInput
        SourceArn: string
        MaxResults: number
    end
    record RemovePermissionOutput
    end
    record AddPermissionInput
        QueueUrl: string
        Label: string
        AWSAccountIds: {string}
        Actions: {string}
    end
    record SendMessageBatchResultEntry
        Id: string
        MessageId: string
        MD5OfMessageBody: string
        MD5OfMessageAttributes: string
        MD5OfMessageSystemAttributes: string
        SequenceNumber: string
    end
    record ChangeMessageVisibilityBatchInput
        QueueUrl: string
        Entries: {ChangeMessageVisibilityBatchRequestEntry}
    end
    record SendMessageBatchInput
        QueueUrl: string
        Entries: {SendMessageBatchRequestEntry}
    end
    record BatchResultErrorEntry
        Id: string
        SenderFault: any
        Code: string
        Message: string
    end
    record GetQueueAttributesInput
        QueueUrl: string
        AttributeNames: {string}
    end
    record AddPermissionOutput
    end
    record SendMessageInput
        QueueUrl: string
        MessageBody: string
        DelaySeconds: number
        MessageAttributes: {string: MessageAttributeValue}
        MessageSystemAttributes: {string: MessageSystemAttributeValue}
        MessageDeduplicationId: string
        MessageGroupId: string
    end
    record GetQueueUrlOutput
        QueueUrl: string
    end
    record RemovePermissionInput
        QueueUrl: string
        Label: string
    end
    record ListDeadLetterSourceQueuesInput
        QueueUrl: string
        NextToken: string
        MaxResults: number
    end
    record MessageSystemAttributeValue
        StringValue: string
        BinaryValue: any
        StringListValues: {string}
        BinaryListValues: {any}
        DataType: string
    end
    record DeleteQueueInput
        QueueUrl: string
    end
    record SendMessageBatchOutput
        Successful: {SendMessageBatchResultEntry}
        Failed: {BatchResultErrorEntry}
    end
    record MessageAttributeValue
        StringValue: string
        BinaryValue: any
        StringListValues: {string}
        BinaryListValues: {any}
        DataType: string
    end
    record ChangeMessageVisibilityInput
        QueueUrl: string
        ReceiptHandle: string
        VisibilityTimeout: number
    end
    record ReceiveMessageOutput
        Messages: {Message}
    end
    record ChangeMessageVisibilityBatchOutput
        Successful: {ChangeMessageVisibilityBatchResultEntry}
        Failed: {BatchResultErrorEntry}
    end
    record DeleteMessageBatchRequestEntry
        Id: string
        ReceiptHandle: string
    end
    record ReceiveMessageInput
        QueueUrl: string
        AttributeNames: {string}
        MessageSystemAttributeNames: {string}
        MessageAttributeNames: {string}
        MaxNumberOfMessages: number
        VisibilityTimeout: number
        WaitTimeSeconds: number
        ReceiveRequestAttemptId: string
    end
    
    record Config
        Region: string
        Credentials: sigv4.Credentials
        HTTPClient: http.Client
    end
    New: function(config: Config): module
    AddPermission: function(self, input: AddPermissionInput): AddPermissionOutput
    CancelMessageMoveTask: function(self, input: CancelMessageMoveTaskInput): CancelMessageMoveTaskOutput
    ChangeMessageVisibility: function(self, input: ChangeMessageVisibilityInput): ChangeMessageVisibilityOutput
    ChangeMessageVisibilityBatch: function(self, input: ChangeMessageVisibilityBatchInput): ChangeMessageVisibilityBatchOutput
    CreateQueue: function(self, input: CreateQueueInput): CreateQueueOutput
    DeleteMessage: function(self, input: DeleteMessageInput): DeleteMessageOutput
    DeleteMessageBatch: function(self, input: DeleteMessageBatchInput): DeleteMessageBatchOutput
    DeleteQueue: function(self, input: DeleteQueueInput): DeleteQueueOutput
    GetQueueAttributes: function(self, input: GetQueueAttributesInput): GetQueueAttributesOutput
    GetQueueUrl: function(self, input: GetQueueUrlInput): GetQueueUrlOutput
    ListDeadLetterSourceQueues: function(self, input: ListDeadLetterSourceQueuesInput): ListDeadLetterSourceQueuesOutput
    ListMessageMoveTasks: function(self, input: ListMessageMoveTasksInput): ListMessageMoveTasksOutput
    ListQueues: function(self, input: ListQueuesInput): ListQueuesOutput
    ListQueueTags: function(self, input: ListQueueTagsInput): ListQueueTagsOutput
    PurgeQueue: function(self, input: PurgeQueueInput): PurgeQueueOutput
    ReceiveMessage: function(self, input: ReceiveMessageInput): ReceiveMessageOutput
    RemovePermission: function(self, input: RemovePermissionInput): RemovePermissionOutput
    SendMessage: function(self, input: SendMessageInput): SendMessageOutput
    SendMessageBatch: function(self, input: SendMessageBatchInput): SendMessageBatchOutput
    SetQueueAttributes: function(self, input: SetQueueAttributesInput): SetQueueAttributesOutput
    StartMessageMoveTask: function(self, input: StartMessageMoveTaskInput): StartMessageMoveTaskOutput
    TagQueue: function(self, input: TagQueueInput): TagQueueOutput
    UntagQueue: function(self, input: UntagQueueInput): UntagQueueOutput
end
return module
