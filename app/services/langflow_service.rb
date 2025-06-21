class LangflowService
  include HTTParty
  
  def initialize
    @base_url = ENV['LANGFLOW_URL'] || 'http://localhost:7860'
    @api_key = ENV['LANGFLOW_API_KEY']
    @flow_id = ENV['LANGFLOW_FLOW_ID']
    
    self.class.base_uri @base_url
  end
  
  def run_flow(prompt, session_id = nil, streaming = false)
    endpoint = "/api/v1/run/#{@flow_id}"
    
    body = {
      input_value: prompt,
      output_type: "chat",
      input_type: "chat"
    }
    
    body[:session_id] = session_id if session_id
    body[:stream] = streaming if streaming
    
    headers = {
      'Content-Type' => 'application/json',
      'Accept' => streaming ? 'text/event-stream' : 'application/json'
    }
    
    headers['Authorization'] = "Bearer #{@api_key}" if @api_key
    
    Rails.logger.info "Calling Langflow: #{endpoint} with prompt: #{prompt}"
    
    if streaming
      stream_response(endpoint, body, headers, session_id)
    else
      response = self.class.post(endpoint, body: body.to_json, headers: headers)
      
      if response.success?
        parse_langflow_response(response.parsed_response)
      else
        Rails.logger.error "Langflow API error: #{response.code} - #{response.body}"
        "I'm sorry, there was an error processing your request."
      end
    end
  end
  
  private
  
  def stream_response(endpoint, body, headers, session_id)
    # For streaming, we'll need to handle Server-Sent Events
    # This is a simplified version - in production you might want to use EventMachine or similar
    
    uri = URI.parse("#{@base_url}#{endpoint}")
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    
    request = Net::HTTP::Post.new(uri.request_uri, headers)
    request.body = body.to_json
    
    chunks = []
    
    http.request(request) do |response|
      if response.code == '200'
        response.read_body do |chunk|
          # Parse SSE chunks
          chunk.each_line do |line|
            if line.start_with?('data: ')
              data = line[6..-1].strip
              next if data.empty? || data == '[DONE]'
              
              begin
                parsed_data = JSON.parse(data)
                if parsed_data['event'] == 'token'
                  chunks << parsed_data.dig('data', 'chunk')
                end
              rescue JSON::ParserError
                # Skip invalid JSON
              end
            end
          end
        end
      else
        Rails.logger.error "Langflow streaming error: #{response.code} - #{response.body}"
        return "I'm sorry, there was an error processing your request."
      end
    end
    
    chunks.join('')
  end
  
  def parse_langflow_response(response)
    # Extract the text response from Langflow's response format
    if response.is_a?(Hash)
      # Try different possible response formats
      text = response.dig('outputs', 0, 'outputs', 0, 'results', 'message', 'text') ||
             response.dig('outputs', 0, 'outputs', 0, 'results', 'text') ||
             response.dig('message', 'text') ||
             response.dig('text') ||
             response.to_s
      
      return text
    end
    
    response.to_s
  end
end 