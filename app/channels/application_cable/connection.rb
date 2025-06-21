module ApplicationCable
  class Connection < ActionCable::Connection::Base
    identified_by :call_sid

    def connect
      self.call_sid = request.params[:call_sid] || request.headers['X-Call-Sid'] || SecureRandom.uuid
      Rails.logger.info "WebSocket connected: #{call_sid} from #{request.remote_ip}"
    end

    def disconnect
      Rails.logger.info "WebSocket disconnected: #{call_sid}"
    end

    # Override ActionCable's receive method to handle ConversationRelay
    def receive(data)
      Rails.logger.info "ConversationRelay received: #{data.inspect}"
      
      begin
        message = JSON.parse(data)
        
        case message['type']
        when 'setup'
          handle_setup(message)
        when 'prompt'
          handle_prompt(message)
        when 'ping'
          # Ignore ping messages - they're just keepalives
          Rails.logger.debug "Ping received: #{message['message']}"
        when 'interrupt'
          handle_interrupt(message)
        else
          Rails.logger.warn "Unknown message type: #{message['type']}"
        end
      rescue JSON::ParserError => e
        Rails.logger.error "JSON parse error: #{e.message}"
        Rails.logger.error "Raw data: #{data.inspect}"
      rescue => e
        Rails.logger.error "Error processing message: #{e.message}"
        Rails.logger.error e.backtrace.join("\n")
      end
    end

    private

    def handle_setup(message)
      Rails.logger.info "Setup: #{message.inspect}"
      # Setup message has sessionId, not sequenceId
      send_message({ type: 'setup-complete' })
    end

    def handle_prompt(message)
      Rails.logger.info "Processing prompt: #{message['voicePrompt']}"
      
      # Quick hackathon response
      response_text = "I heard you say: #{message['voicePrompt']}. How can I help you today?"
      
      send_message({
        type: 'text',
        token: response_text,
        last: true
      })
    end

    def handle_interrupt(message)
      send_message({ type: 'interrupt-handled' })
    end

    def send_message(data)
      Rails.logger.info "Sending to ConversationRelay: #{data.inspect}"
      # Use ActionCable's transmit method with the JSON data
      transmit(data)
    end
  end
end 