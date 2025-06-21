class McpController < ApplicationController
  include ActionController::Live
  skip_before_action :verify_authenticity_token
  
  # MCP Protocol constants
  PROTOCOL_VERSION = '2025-03-26'.freeze
  SESSION_HEADER = 'Mcp-Session-Id'.freeze
  PROTOCOL_HEADER = 'MCP-Protocol-Version'.freeze
  
  # Main MCP endpoint handler
  def handle_mcp
    # Log ALL incoming requests with full details
    Rails.logger.info "=== INCOMING #{request.method} REQUEST ==="
    Rails.logger.info "User-Agent: #{request.headers['User-Agent']}"
    Rails.logger.info "Content-Type: #{request.headers['Content-Type']}"
    Rails.logger.info "Accept: #{request.headers['Accept']}"
    Rails.logger.info "MCP-Protocol-Version: #{request.headers['MCP-Protocol-Version']}"
    Rails.logger.info "Mcp-Session-Id: #{request.headers['Mcp-Session-Id']}"
    Rails.logger.info "Origin: #{request.headers['Origin']}"
    Rails.logger.info "Request body size: #{request.body.size}" if request.body
    
    case request.method
    when 'POST'
      handle_post_request
    when 'GET'
      handle_get_request
    when 'HEAD'
      handle_head_request
    when 'OPTIONS'
      handle_options_request
    when 'DELETE'
      handle_delete_request
    else
      Rails.logger.info "Unsupported method: #{request.method}"
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
    Rails.logger.info "=== PROCESSING POST REQUEST ==="
    
    # validate_protocol_version!
    return unless validate_accept_headers_for_post!
    
    message = parse_jsonrpc_message
    return unless message
    
    Rails.logger.info "JSON-RPC Message: #{message.to_json}"
    Rails.logger.info "Method: #{message['method']}, ID: #{message['id']}"
    
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

  # Handle HEAD requests (endpoint health check)
  def handle_head_request
    Rails.logger.info "HEAD request - MCP endpoint health check"
    
    # Return the same headers as a GET request would, but no body
    response.headers['Content-Type'] = 'application/json'
    response.headers['Accept'] = 'application/json, text/event-stream'
    response.headers['MCP-Protocol-Version'] = PROTOCOL_VERSION
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, HEAD, DELETE, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id'
    
    head :ok
  end

  # Handle OPTIONS requests (CORS preflight)
  def handle_options_request
    Rails.logger.info "OPTIONS request - CORS preflight check"
    
    # CORS preflight response
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Methods'] = 'GET, POST, HEAD, DELETE, OPTIONS'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id, Authorization'
    response.headers['Access-Control-Max-Age'] = '3600'
    
    head :ok
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
      start_time = Time.current
      last_heartbeat = start_time
      
      loop do
        # Check for server messages to send
        send_pending_server_messages(session_id)
        
        # Check if it's time for a heartbeat (every 30 seconds, not blocking)
        current_time = Time.current
        if current_time - last_heartbeat >= 30
          Rails.logger.info "Sending keep-alive heartbeat to session #{session_id}"
          sse_write('heartbeat', {
            type: 'heartbeat',
            timestamp: current_time.iso8601,
            session_id: session_id,
            uptime_seconds: (current_time - start_time).to_i
          }.to_json)
          last_heartbeat = current_time
        end
        
        # Very short sleep to prevent CPU spinning, but stay responsive
        sleep 0.1
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
      
      # Keep the connection open without blocking
      # The client will send POST requests which will be handled by separate controller actions
      Rails.logger.info "SSE stream established, waiting for client requests..."
      
      # Use a simple non-blocking approach - just keep the stream alive
      # Send occasional keep-alive messages but don't block for long periods
      start_time = Time.current
      last_heartbeat = start_time
      
      loop do
        # Check if it's time for a heartbeat (every 30 seconds, not blocking)
        current_time = Time.current
        if current_time - last_heartbeat >= 30
          Rails.logger.info "Sending keep-alive heartbeat"
          sse_write('heartbeat', {
            type: 'heartbeat',
            timestamp: current_time.iso8601,
            uptime_seconds: (current_time - start_time).to_i
          }.to_json)
          last_heartbeat = current_time
        end
        
        # Very short sleep to prevent CPU spinning, but stay responsive
        sleep 0.1
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
    
    # For initialize requests, ensure session exists (create if needed)
    if message['method'] == 'initialize'
      if session_id.nil?
        # No session ID provided, create a new one
        session_id = McpSession.create
      else
        # Session ID provided by client, create it in cache if it doesn't exist
        unless McpSession.exists?(session_id)
          session_data = {
            created_at: Time.current.iso8601,
            initialized: false,
            protocol_version: nil
          }
          Rails.cache.write("mcp_session_#{session_id}", session_data, expires_in: 1.hour)
          Rails.logger.info "Created MCP session from client ID: #{session_id}"
        end
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
    response.headers['Cache-Control'] = 'no-cache, no-store, must-revalidate'
    response.headers['Connection'] = 'keep-alive'
    response.headers['X-Accel-Buffering'] = 'no'  # Disable nginx buffering
    response.headers['X-Proxy-Buffering'] = 'no'  # Disable proxy buffering
    response.headers['Transfer-Encoding'] = 'chunked'  # Enable chunked transfer
    response.headers['Access-Control-Allow-Origin'] = '*'
    response.headers['Access-Control-Allow-Headers'] = 'Content-Type, Accept, MCP-Protocol-Version, Mcp-Session-Id'
  end

  # SSE writing helpers
  def sse_write(event_type, data)
    Rails.logger.info "SSE SEND -> event: #{event_type}"
    Rails.logger.info "SSE SEND -> data: #{data}"
    response.stream.write("event: #{event_type}\n")
    response.stream.write("data: #{data}\n\n")
    
    # Force immediate flush to prevent buffering
    if response.stream.respond_to?(:flush)
      response.stream.flush
    end
    
    # Additional flush for Rails ActionController::Live
    if response.stream.respond_to?(:close_write)
      # Don't close, just ensure data is sent immediately
    end
  rescue IOError => e
    Rails.logger.error "Failed to write to SSE stream: #{e.message}"
    raise # Re-raise to trigger cleanup
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
        name: "find_client",
        description: "Search for existing client by first and last name",
        inputSchema: {
          type: "object",
          properties: {
            first_name: {
              type: "string",
              description: "Client's first name"
            },
            last_name: {
              type: "string", 
              description: "Client's last name"
            }
          },
          required: ["first_name", "last_name"]
        }
      },
      {
        name: "create_client",
        description: "Create a new client record",
        inputSchema: {
          type: "object",
          properties: {
            name: {
              type: "string",
              description: "Full name of the client"
            },
            phone: {
              type: "string",
              description: "Phone number"
            }
          },
          required: ["name"]
        }
      },
      {
        name: "list_services",
        description: "Get all available services",
        inputSchema: {
          type: "object",
          properties: {}
        }
      },
      {
        name: "get_client_history",
        description: "Get past bookings for a client",
        inputSchema: {
          type: "object",
          properties: {
            client_id: {
              type: "integer",
              description: "ID of the client"
            }
          },
          required: ["client_id"]
        }
      },
      {
        name: "check_availability",
        description: "Find the next available time slot for a service on or after a preferred date",
        inputSchema: {
          type: "object",
          properties: {
            service_id: {
              type: "integer",
              description: "ID of the service"
            },
            preferred_date: {
              type: "string",
              description: "Preferred date in YYYY-MM-DD format (optional, defaults to tomorrow)"
            }
          },
          required: ["service_id"]
        }
      },
      {
        name: "create_booking",
        description: "Create a new booking",
        inputSchema: {
          type: "object",
          properties: {
            client_id: {
              type: "integer",
              description: "ID of the client"
            },
            service_id: {
              type: "integer",
              description: "ID of the service"
            },
            start_time: {
              type: "string",
              description: "Start time in ISO datetime format"
            }
          },
          required: ["client_id", "service_id", "start_time"]
        }
      }
    ]

    jsonrpc_success({ tools: tools }, id)
  end

  def handle_tools_call(params, id)
    tool_name = params["name"]
    arguments = params["arguments"] || {}

    case tool_name
    when "find_client"
      result = find_client_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    when "create_client"
      result = create_client_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    when "list_services"
      result = list_services_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    when "get_client_history"
      result = get_client_history_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    when "check_availability"
      result = check_availability_tool(arguments)
      jsonrpc_success({ content: [{ type: "text", text: result }] }, id)
    when "create_booking"
      result = create_booking_tool(arguments)
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

  # Salon booking tool implementations
  def find_client_tool(arguments)
    first_name = arguments["first_name"].strip
    last_name = arguments["last_name"].strip
    
    # Search by first and last name using ActiveRecord (case-insensitive)
    # Try "First Last" and "Last First" patterns
    client = Client.where("LOWER(name) LIKE LOWER(?)", "%#{first_name}%#{last_name}%")
                   .or(Client.where("LOWER(name) LIKE LOWER(?)", "%#{last_name}%#{first_name}%"))
                   .first
    
    if client
      {
        found: true,
        client: {
          id: client.id,
          name: client.name,
          phone: client.phone,
          total_bookings: client.bookings.count,
          last_visit: client.bookings.maximum(:start_time)&.strftime("%B %d, %Y")
        }
      }.to_json
    else
      { 
        found: false, 
        message: "No client found matching '#{first_name} #{last_name}'" 
      }.to_json
    end
  end

  def create_client_tool(arguments)
    client = Client.create!(
      name: arguments["name"],
      phone: arguments["phone"]
    )
    
    {
      success: true,
      client: {
        id: client.id,
        name: client.name,
        phone: client.phone
      },
      message: "Client #{client.name} created successfully"
    }.to_json
  rescue => e
    { success: false, error: e.message }.to_json
  end

  def list_services_tool(arguments)
    services = Service.where(active: true).order(:name)
    
    {
      services: services.map do |service|
        {
          id: service.id,
          name: service.name,
          description: service.description,
          duration_minutes: service.duration_minutes,
          price: "$#{service.price_cents / 100}",
          duration_display: "#{service.duration_minutes} minutes"
        }
      end
    }.to_json
  end

  def get_client_history_tool(arguments)
    client = Client.find(arguments["client_id"])
    bookings = client.bookings.includes(:service).order(start_time: :desc).limit(10)
    
    {
      client_name: client.name,
      total_bookings: client.bookings.count,
      recent_bookings: bookings.map do |booking|
        {
          id: booking.id,
          service_name: booking.service.name,
          date: booking.start_time.strftime("%B %d, %Y"),
          time: booking.start_time.strftime("%I:%M %p"),
          status: booking.status,
          notes: booking.notes
        }
      end
    }.to_json
  rescue ActiveRecord::RecordNotFound
    { error: "Client not found" }.to_json
  end

  def check_availability_tool(arguments)
    service = Service.find(arguments["service_id"])
    preferred_date = arguments["preferred_date"] ? Date.parse(arguments["preferred_date"]) : Date.tomorrow
    
    # Skip past dates
    check_date = preferred_date < Date.tomorrow ? Date.tomorrow : preferred_date
    
    # Define business hours (9 AM to 6 PM)
    day_start = check_date.beginning_of_day + 9.hours
    day_end = check_date.beginning_of_day + 18.hours
    
    # Get existing bookings for this date
    existing_bookings = Booking.where(start_time: day_start..day_end).order(:start_time)
    
    # Find first available slot
    current_time = day_start
    while current_time + service.duration_minutes.minutes <= day_end
      slot_end = current_time + service.duration_minutes.minutes
      
      # Check if this slot conflicts with existing bookings
      conflict = existing_bookings.any? do |booking|
        current_time < booking.end_time && slot_end > booking.start_time
      end
      
      unless conflict
        # Found an available slot - return it
        return {
          success: true,
          service_name: service.name,
          service_duration: "#{service.duration_minutes} minutes",
          recommended_slot: {
            date: check_date.strftime("%A, %B %d, %Y"),
            start_time: current_time.strftime("%I:%M %p"),
            end_time: slot_end.strftime("%I:%M %p"),
            iso_start_time: current_time.iso8601
          }
        }.to_json
      end
      
      current_time += 30.minutes
    end
    
    # No slots available on preferred date - try next day
    next_day = check_date + 1.day
    if next_day <= Date.current + 7.days # Only check up to a week ahead
      return check_availability_tool({
        "service_id" => arguments["service_id"],
        "preferred_date" => next_day.strftime("%Y-%m-%d")
      })
    end
    
    # No availability found
    {
      success: false,
      message: "Sorry, no availability found in the next week. Please try a different time period."
    }.to_json
  rescue ActiveRecord::RecordNotFound
    { error: "Service not found" }.to_json
  end

  def create_booking_tool(arguments)
    client = Client.find(arguments["client_id"])
    service = Service.find(arguments["service_id"])
    start_time = Time.parse(arguments["start_time"])
    end_time = start_time + service.duration_minutes.minutes
    
    # Double-check availability using proper overlap detection
    # A booking overlaps if it starts before our booking ends AND ends after our booking starts
    conflict = Booking.where(start_time: ...end_time)
                     .where("end_time > ?", start_time)
                     .exists?
    
    if conflict
      return { success: false, error: "Time slot no longer available" }.to_json
    end
    
    booking = Booking.create!(
      client: client,
      service: service,
      start_time: start_time,
      end_time: end_time,
      status: 'confirmed'
    )
    
    {
      success: true,
      booking: {
        id: booking.id,
        client_name: client.name,
        service_name: service.name,
        date: start_time.strftime("%A, %B %d, %Y"),
        time: "#{start_time.strftime('%I:%M %p')} - #{end_time.strftime('%I:%M %p')}",
        status: booking.status
      },
      message: "Booking confirmed for #{client.name}"
    }.to_json
  rescue => e
    { success: false, error: e.message }.to_json
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