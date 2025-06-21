class ConversationRelayChannel < ApplicationCable::Channel
  def subscribed
    # ConversationRelay connects directly without traditional subscriptions
    Rails.logger.info "ConversationRelay WebSocket connection established"
  end

  def unsubscribed
    Rails.logger.info "ConversationRelay WebSocket connection closed"
  end

  def receive(data)
    Rails.logger.info "ConversationRelay received: #{data.inspect}"
    
    begin
      # Parse the incoming ConversationRelay message
      message = data.is_a?(String) ? JSON.parse(data) : data
      
      case message['type']
      when 'setup'
        handle_setup(message)
      when 'prompt'
        handle_prompt(message)
      when 'interrupt'
        handle_interrupt(message)
      else
        Rails.logger.warn "Unknown ConversationRelay message type: #{message['type']}"
      end
    rescue JSON::ParserError => e
      Rails.logger.error "Failed to parse ConversationRelay message: #{e.message}"
    rescue => e
      Rails.logger.error "Error handling ConversationRelay message: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
    end
  end

  private

  def handle_setup(message)
    Rails.logger.info "ConversationRelay setup: #{message.inspect}"
    
    # Store call information
    @call_sid = message['callSid']
    @sequence_id = message['sequenceId']
    
    # Acknowledge setup
    send_response({
      type: 'setup-complete',
      sequenceId: @sequence_id
    })
  end

  def handle_prompt(message)
    Rails.logger.info "Processing prompt: #{message['voicePrompt']}"
    
    voice_prompt = message['voicePrompt']
    sequence_id = message['sequenceId']
    call_sid = message['callSid']
    
    # Process directly in the channel - scrappy hackathon style!
    begin
      langflow_service = LangflowService.new
      
      # Check if streaming is enabled
      streaming_enabled = ENV['LANGFLOW_STREAMING'] == 'true'
      
      if streaming_enabled
        # Handle streaming response
        handle_streaming_response(voice_prompt, call_sid, sequence_id)
      else
        # Handle regular response
        response_text = langflow_service.run_flow(voice_prompt, call_sid, false)
        
        send_response({
          type: 'text',
          token: response_text,
          last: true,
          sequenceId: sequence_id
        })
      end
    rescue => e
      Rails.logger.error "Error processing prompt: #{e.message}"
      Rails.logger.error e.backtrace.join("\n")
      
      send_response({
        type: 'text',
        token: "I'm sorry, there was an error processing your request.",
        last: true,
        sequenceId: sequence_id
      })
    end
  end

  def handle_interrupt(message)
    Rails.logger.info "ConversationRelay interrupt: #{message.inspect}"
    
    # Handle interruption - stop current processing if needed
    send_response({
      type: 'interrupt-handled',
      sequenceId: message['sequenceId']
    })
  end

  def handle_streaming_response(prompt, call_sid, sequence_id)
    # Scrappy streaming implementation
    langflow_service = LangflowService.new
    
    # Get the full response first, then simulate streaming
    response_text = langflow_service.run_flow(prompt, call_sid, false)
    
    # Split response into words for pseudo-streaming
    words = response_text.split(' ')
    
    words.each_with_index do |word, index|
      send_response({
        type: 'text',
        token: word + ' ',
        last: index == words.length - 1,
        sequenceId: sequence_id
      })
      
      # Small delay to simulate streaming (optional, can remove for even more speed)
      sleep(0.05)
    end
  end

  def send_response(data)
    Rails.logger.info "Sending ConversationRelay response: #{data.inspect}"
    
    # Send the response back to Twilio ConversationRelay
    transmit(data)
  end
end 