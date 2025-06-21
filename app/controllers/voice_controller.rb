class VoiceController < ApplicationController
  protect_from_forgery with: :null_session
  
  def voice
    Rails.logger.info "Voice webhook received from: #{request.remote_ip}"
    Rails.logger.info "Request params: #{params.inspect}"
    
    # Get the tunnel URL from environment or request
    tunnel_url = ENV['TUNNEL_DOMAIN'] || request.host_with_port
    websocket_url = "wss://#{tunnel_url}/cable"
    
    Rails.logger.info "Connecting to WebSocket: #{websocket_url}"
    
    # Generate ConversationRelay TwiML manually
    twiml = <<~XML
      <?xml version="1.0" encoding="UTF-8"?>
      <Response>
        <Connect>
          <ConversationRelay url="#{websocket_url}" welcomeGreeting="Hello! I'm your AI assistant. How can I help you today?" />
        </Connect>
      </Response>
    XML
    
    Rails.logger.info "Generated TwiML: #{twiml}"
    
    render xml: twiml
  end
end 