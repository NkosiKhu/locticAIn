class McpController < ApplicationController
  include ActionController::Live
  skip_before_action :verify_authenticity_token
  
  # MCP Protocol constants
  PROTOCOL_VERSION = '2025-03-26'.freeze
  SESSION_HEADER = 'Mcp-Session-Id'.freeze
  PROTOCOL_HEADER = 'MCP-Protocol-Version'.freeze
  
  # Main MCP endpoint handler
  def handle_mcp
    case request.method
    when 'POST'
      handle_post_request
    when 'GET'
      handle_get_request
    when 'DELETE'
      handle_delete_request
    else
      head :method_not_allowed
    end
  rescue => e
    Rails.logger.error "MCP Error: #{e.message}"
    Rails.logger.error e.backtrace.join("\n")
    
    if request.method == 'GET' && response.headers['Content-Type'] == 'text/event-stream'
      sse_write_error("Internal server error")
    else
      render json: { 
        error: 'Internal server error',
        timestamp: Time.current.iso8601 
      }, status: 500
    end
  end

  private

  # Handle POST requests (client sending messages to server)
  def handle_post_request
    # validate_protocol_version!
    return unless validate_accept_headers_for_post!
    
    message = parse_jsonrpc_message
    return unless message
    
    session_id = extract_or_create_session(message)
    return unless session_id
    
    case determine_message_type(message)
    when :request
      handle_jsonrpc_request(message, session_id)
    when :notification
      handle_jsonrpc_notification(message, session_id)
    when :response
      handle_jsonrpc_response(message, session_id)
    else
      render json: jsonrpc_error(-32600, "Invalid Request", message['id']), status: 400
    end
  end

  # Handle GET requests (client opening stream for server messages)
  def handle_get_request
    Rails.logger.info "GET request headers: #{request.headers.to_h.select { |k,v| k.start_with?('HTTP_') || k.include?('ACCEPT') || k.include?('MCP') }}"
    
    # Skip protocol validation for GET - Cursor doesn't send MCP-Protocol-Version header on GET
    # validate_protocol_version!
    
    unless accepts_sse?
      Rails.logger.info "GET request failed: Missing Accept: text/event-stream header"
      head :method_not_allowed
      return
    end
    
    # For GET requests, session ID is optional initially
    # Some clients may open stream before sending session ID
    session_id = extract_session_id
    Rails.logger.info "GET request session_id: #{session_id}"
    
    # If no session ID, we can still open a stream and wait for proper requests
    if !session_id
      Rails.logger.info "GET request without session ID - opening generic stream"
      open_generic_message_stream
    elsif McpSession.exists?(session_id)
      Rails.logger.info "GET request with valid session ID - opening session stream"
      open_server_message_stream(session_id)
    else
      Rails.logger.info "GET request with invalid session ID"
      head :bad_request
      return
    end
  end

  # Handle DELETE requests (client terminating session)
  def handle_delete_request
    session_id = extract_session_id
    
    if session_id && McpSession.terminate(session_id)
      head :ok
    else
      head :not_found
    end
  end

  # JSON-RPC Request Handling
  def handle_jsonrpc_request(message, session_id)
    # Extend session on activity
    McpSession.extend_session(session_id) if session_id
    
    # Determine response type based on Accept header preference
    if prefers_sse? && should_stream_response?(message)
      stream_jsonrpc_response(message, session_id)
    else
      json_jsonrpc_response(message, session_id)
    end
  end

  def handle_jsonrpc_notification(message, session_id)
    # Process notification
    process_jsonrpc_message(message, session_id)
    
    # Return 202 Accepted for notifications
    head :accepted
  end

  def handle_jsonrpc_response(message, session_id)
    # Process response (from server perspective, this is rare)
    process_jsonrpc_message(message, session_id)
    
    # Return 202 Accepted for responses
    head :accepted
  end

  # Stream JSON-RPC response via SSE
  def stream_jsonrpc_response(message, session_id)
    Rails.logger.info "=== STREAMING JSON-RPC RESPONSE FOR #{message['method']} ==="
    setup_sse_headers
    
    begin
      Rails.logger.info "Processing message: #{message['method']} (ID: #{message['id']})"
      response_data = process_jsonrpc_message(message, session_id)
      
      Rails.logger.info "Sending JSON-RPC response via SSE..."
      sse_write('message', response_data.to_json)
      
      Rails.logger.info "JSON-RPC response sent, closing stream per MCP spec"
      # Close stream after sending response (per spec)
    ensure
      Rails.logger.info "=== CLOSING JSON-RPC RESPONSE STREAM ==="
      response.stream.close
    end
  end

  # Return JSON-RPC response directly
  def json_jsonrpc_response(message, session_id)
    response_data = process_jsonrpc_message(message, session_id)
    
    # Add session header if this is initialization
    if message['method'] == 'initialize' && session_id
      headers[SESSION_HEADER] = session_id
    end
    
    render json: response_data
  end

  # Open SSE stream for server-initiated messages
  def open_server_message_stream(session_id)
    Rails.logger.info "=== OPENING SERVER MESSAGE STREAM FOR SESSION: #{session_id} ==="
    setup_sse_headers
    
    begin
      # Send initial connection confirmation
      Rails.logger.info "Sending connection confirmation to client..."
      sse_write('connected', {
        type: 'server_stream_established',
        session_id: session_id,
        timestamp: Time.current.iso8601
      }.to_json)
      
      # Keep stream alive and send server messages
      heartbeat_count = 0
      loop do
        # Check for server messages to send
        send_pending_server_messages(session_id)
        
        # Send heartbeat
        heartbeat_count += 1
        Rails.logger.info "Sending heartbeat ##{heartbeat_count} to session #{session_id}"
        sse_write('heartbeat', {
          type: 'heartbeat',
          count: heartbeat_count,
          timestamp: Time.current.iso8601
        }.to_json)
        
        sleep 30
      end
      
    rescue IOError, Errno::ECONNRESET => e
      Rails.logger.info "Server stream closed for session #{session_id}: #{e.message}"
    ensure
      Rails.logger.info "=== CLOSING SERVER MESSAGE STREAM FOR SESSION: #{session_id} ==="
      response.stream.close
    end
  end

  # Open generic SSE stream for clients without session ID
  def open_generic_message_stream
    Rails.logger.info "=== OPENING GENERIC MESSAGE STREAM (NO SESSION ID) ==="
    setup_sse_headers
    
    begin
      # Send initial connection confirmation
      Rails.logger.info "Sending generic connection confirmation to client..."
      sse_write('connected', {
        type: 'generic_stream_established',
        message: 'Server stream ready - send session ID in subsequent requests',
        timestamp: Time.current.iso8601
      }.to_json)
      
      # Keep stream alive with minimal heartbeats
      heartbeat_count = 0
      loop do
        # Send heartbeat
        heartbeat_count += 1
        Rails.logger.info "Sending generic heartbeat ##{heartbeat_count}"
        sse_write('heartbeat', {
          type: 'heartbeat',
          count: heartbeat_count,
          timestamp: Time.current.iso8601
        }.to_json)
        
        sleep 30
      end
      
    rescue IOError, Errno::ECONNRESET => e
      Rails.logger.info "Generic server stream closed: #{e.message}"
    ensure
      Rails.logger.info "=== CLOSING GENERIC MESSAGE STREAM ==="
      response.stream.close
    end
  end

  # Protocol version validation
  def validate_protocol_version!
    protocol_version = request.headers[PROTOCOL_HEADER]
    
    # If no version header, assume latest (for backwards compatibility)
    protocol_version ||= PROTOCOL_VERSION
    
    unless protocol_version == PROTOCOL_VERSION
      render json: { 
        error: "Unsupported protocol version: #{protocol_version}" 
      }, status: 400
      return
    end
  end

  # Session management
  def extract_or_create_session(message)
    session_id = extract_session_id
    
    # For initialize requests, create new session if none provided
    if message['method'] == 'initialize'
      if session_id.nil?
        session_id = McpSession.create
      end
      
      # Mark session as initialized
      protocol_version = request.headers[PROTOCOL_HEADER] || PROTOCOL_VERSION
      McpSession.initialize_session(session_id, protocol_version)
    end
    
    # Validate session exists for non-initialize requests
    if message['method'] != 'initialize'
      unless session_id && McpSession.exists?(session_id)
        render json: { error: 'Invalid or missing session' }, status: 400
        return nil
      end
    end
    
    session_id
  end

  def extract_session_id
    request.headers[SESSION_HEADER]
  end

  # Message parsing and type detection
  def parse_jsonrpc_message
    JSON.parse(request.body.read)
  rescue JSON::ParserError => e
    render json: { error: 'Invalid JSON' }, status: 400
    return nil
  end

  def determine_message_type(message)
    return nil unless message.is_a?(Hash)
    
    if message.key?('method')
      message.key?('id') ? :request : :notification
    elsif message.key?('result') || message.key?('error')
      :response
    else
      :invalid
    end
  end

  # Content type and header helpers
  def validate_accept_headers_for_post!
    accept_header = request.headers['Accept']
    unless accept_header&.include?('application/json') && accept_header&.include?('text/event-stream')
      render json: { error: 'POST requests must accept both application/json and text/event-stream' }, status: 400
      return false
    end
    return true
  end

  def accepts_sse?
    request.headers['Accept']&.include?('text/event-stream')
  end

  def prefers_sse?
    accept_header = request.headers['Accept']
    return false unless accept_header
    
    # Only prefer SSE if text/event-stream comes FIRST in Accept header
    # This is a conservative approach - client must explicitly prefer SSE
    accept_header.strip.start_with?('text/event-stream')
  end

  def should_stream_response?(message)
    # For now, stream all requests that prefer SSE
    # Could add logic for specific methods that benefit from streaming
    true
  end

  def setup_sse_headers
    response.headers['Content-Type'] = 'text/event-stream'
    response.headers['Cache-Control'] = 'no-cache'
    response.headers['Connection'] = 'keep-alive'
    response.headers['X-Accel-Buffering'] = 'no'
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id'
  end

  # SSE writing helpers
  def sse_write(event_type, data)
    Rails.logger.info "SSE SEND -> event: #{event_type}"
    Rails.logger.info "SSE SEND -> data: #{data}"
    response.stream.write("event: #{event_type}\n")
    response.stream.write("data: #{data}\n\n")
    response.stream.flush if response.stream.respond_to?(:flush)
  rescue IOError => e
    Rails.logger.error "Failed to write to SSE stream: #{e.message}"
  end

  def sse_write_error(message)
    error_data = {
      jsonrpc: "2.0",
      error: {
        code: -32603,
        message: message
      },
      id: nil
    }
    sse_write('error', error_data.to_json)
  end

  # Placeholder for server message handling
  def send_pending_server_messages(session_id)
    # TODO: Implement server-initiated message queue
    # This would check for any pending server messages and send them
  end

  # Main message processor (delegates to existing MCP logic)
  def process_jsonrpc_message(message, session_id)
    # Validate JSON-RPC 2.0 format
    unless message["jsonrpc"] == "2.0"
      return jsonrpc_error(-32600, "Invalid Request", message["id"])
    end

    method_name = message["method"]
    params = message["params"] || {}
    id = message["id"]

    case method_name
    when "initialize"
      handle_initialize(params, id, session_id)
    when "tools/list"
      handle_tools_list(params, id)
    when "tools/call"
      handle_tools_call(params, id)
    when "resources/list"
      handle_resources_list(params, id)
    when "resources/read"
      handle_resources_read(params, id)
    when "prompts/list"
      handle_prompts_list(params, id)
    when "prompts/get"
      handle_prompts_get(params, id)
    else
      jsonrpc_error(-32601, "Method not found", id)
    end
  end

  # JSON-RPC method implementations (updated for spec compliance)
  def handle_initialize(params, id, session_id)
    jsonrpc_success({
      protocolVersion: PROTOCOL_VERSION,
      capabilities: {
        tools: {},
        resources: {},
        prompts: {},
        notifications: {}
      },
      serverInfo: {
        name: "Rails MCP Server",
        version: "1.0.0"
      }
    }, id)
  end

  def handle_tools_list(params, id)
    tools = [
      {
        name: "get_client",
        description: "Retrieve client information from the database",
        inputSchema: {
          type: "object",
          properties: {
            email: {
              type: "string",
              description: "The email of the client to retrieve"
            }
          },
          required: ["email"]
        }
      }
    ]

    jsonrpc_success({ tools: tools }, id)
  end

  def handle_tools_call(params, id)
    tool_name = params["name"]
    arguments = params["arguments"] || {}

    case tool_name
    when "get_client"
      result = get_client_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    else
      jsonrpc_error(-32601, "Tool not found", id)
    end
  end

  def handle_resources_list(params, id)
    resources = [
      {
        uri: "rails://clients",
        name: "Clients Database",
        description: "Access to client records",
        mimeType: "application/json"
      }
    ]

    jsonrpc_success({ resources: resources }, id)
  end

  def handle_resources_read(params, id)
    uri = params["uri"]
    
    case uri
    when "rails://clients"
      clients = Client.select(:name, :email).limit(100)
      content = JSON.pretty_generate(clients)
      
      jsonrpc_success({
        contents: [{
          uri: uri,
          mimeType: "application/json",
          text: content
        }]
      }, id)
    else
      jsonrpc_error(-32601, "Resource not found", id)
    end
  end

  def handle_prompts_list(params, id)
    prompts = [
      {
        name: "client_summary",
        description: "Generate a summary of client activity",
        arguments: [
          {
            name: "client_email",
            description: "The email of the client",
            required: true
          }
        ]
      }
    ]

    jsonrpc_success({ prompts: prompts }, id)
  end

  def handle_prompts_get(params, id)
    prompt_name = params["name"]
    arguments = params["arguments"] || {}

    case prompt_name
    when "client_summary"
      client_email = arguments["client_email"]
      client = Client.find_by(email: client_email)
      return jsonrpc_error(-32602, "Client not found", id) unless client
      
      booking_count = client.bookings.count
      
      prompt_text = "Please provide a summary for client #{client.name} (Email: #{client.email}). " \
                   "They have #{booking_count} bookings and joined on #{client.created_at.strftime('%B %d, %Y')}."
      
      jsonrpc_success({
        description: "Client summary prompt",
        messages: [
          {
            role: "user",
            content: {
              type: "text",
              text: prompt_text
            }
          }
        ]
      }, id)
    else
      jsonrpc_error(-32601, "Prompt not found", id)
    end
  end

  # Tool implementations
  def get_client_tool(arguments)
    email = arguments["email"]
    client = Client.find_by(email: email)
    
    return "Client with email #{email} not found" unless client
    
    {
      id: client.id,
      name: client.name,
      email: client.email,
      created_at: client.created_at
    }.to_json
  end

  # JSON-RPC response helpers
  def jsonrpc_success(result, id)
    {
      jsonrpc: "2.0",
      result: result,
      id: id
    }
  end

  def jsonrpc_error(code, message, id)
    {
      jsonrpc: "2.0",
      error: {
        code: code,
        message: message
      },
      id: id
    }
  end
end