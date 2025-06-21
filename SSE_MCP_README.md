# MCP Server with Server-Sent Events (SSE) Support

This Rails application now supports the Model Context Protocol (MCP) over both traditional HTTP and Server-Sent Events (SSE) connections.

## Features

- **Traditional HTTP MCP**: Standard request/response pattern
- **SSE MCP**: Persistent connections with real-time communication
- **Connection Management**: Automatic connection tracking and cleanup
- **Heartbeat**: Keep-alive mechanism for long-running connections
- **CORS Support**: Cross-origin requests enabled for web clients

## Endpoints

### HTTP Endpoints
- `POST /mcp` - Handle standard MCP requests
- `GET /mcp` - Health check endpoint

### SSE Endpoints
- `GET /mcp/sse` - Establish SSE connection
- `POST /mcp/sse/message` - Send MCP requests over existing SSE connection

## How SSE MCP Works

1. **Connection Establishment**: Client connects to `/mcp/sse` and receives a unique `connection_id`
2. **Request Handling**: Client sends MCP requests to `/mcp/sse/message` with the `connection_id`
3. **Response Delivery**: Server processes requests and sends responses via the SSE connection
4. **Connection Management**: Server automatically tracks and cleans up connections

## Usage Example

### JavaScript Client

```javascript
// Establish SSE connection
const eventSource = new EventSource('/mcp/sse');
let connectionId = null;

// Handle connection established
eventSource.addEventListener('connected', function(event) {
    const data = JSON.parse(event.data);
    connectionId = data.connection_id;
    console.log('Connected with ID:', connectionId);
});

// Handle MCP responses
eventSource.addEventListener('mcp_response', function(event) {
    const response = JSON.parse(event.data);
    console.log('MCP Response:', response);
});

// Send MCP request
async function sendMCPRequest(method, params = {}) {
    const request = {
        jsonrpc: '2.0',
        method: method,
        params: params,
        id: Date.now(),
        connection_id: connectionId
    };

    const response = await fetch('/mcp/sse/message', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(request)
    });

    return response.json();
}

// Example usage
sendMCPRequest('tools/list');
sendMCPRequest('tools/call', { name: 'get_client', arguments: { email: 'test@example.com' } });
```

## Testing

A complete HTML example is available at `/mcp_sse_example.html` after starting the server. This provides a web interface to:

- Connect/disconnect from SSE
- Send various MCP requests
- View real-time responses and events
- Monitor connection status

## SSE Events

The server sends the following SSE event types:

- `connected` - Initial connection establishment with connection ID
- `heartbeat` - Periodic keep-alive messages (every 30 seconds)
- `mcp_response` - MCP protocol responses to client requests
- `error` - Error messages and notifications

## Benefits of SSE over HTTP

1. **Persistent Connection**: No need to establish new connections for each request
2. **Real-time Updates**: Server can push notifications and updates to clients
3. **Lower Latency**: Reduced overhead for frequent communications
4. **Automatic Reconnection**: Built-in browser support for connection recovery
5. **Better Resource Usage**: Single connection vs multiple HTTP requests

## Configuration

The SSE implementation includes:

- CORS headers for cross-origin requests
- Connection pooling and management
- Automatic cleanup of disconnected clients
- Error handling and logging
- Heartbeat mechanism for connection health

## Limitations

- SSE is unidirectional (server-to-client), so client requests still use HTTP POST
- Connection state is stored in memory (consider Redis for production scaling)
- Each SSE connection consumes a server thread while active

## Production Considerations

For production deployments:

1. **Connection Limits**: Monitor concurrent SSE connections
2. **Resource Usage**: Each connection uses memory and a thread
3. **Load Balancing**: Sticky sessions required for connection persistence
4. **Scaling**: Consider using Redis or similar for connection state storage
5. **Monitoring**: Track connection health and cleanup failed connections

## Testing the Implementation

1. Start your Rails server: `rails server`
2. Visit `/mcp_sse_example.html` in your browser
3. Click "Connect to SSE" to establish a connection
4. Use the interface to send various MCP requests
5. Monitor the real-time responses in the events log

The example interface provides a complete demonstration of the SSE MCP functionality. 