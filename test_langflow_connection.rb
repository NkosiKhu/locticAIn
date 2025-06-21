#!/usr/bin/env ruby
# Simple test script to verify Langflow connection

require 'httparty'
require 'json'

# Configuration
LANGFLOW_URL = ENV['LANGFLOW_URL'] || 'http://localhost:7860'
LANGFLOW_API_KEY = ENV['LANGFLOW_API_KEY']
LANGFLOW_FLOW_ID = ENV['LANGFLOW_FLOW_ID']

def test_langflow_connection
  puts "Testing Langflow connection..."
  puts "URL: #{LANGFLOW_URL}"
  puts "Flow ID: #{LANGFLOW_FLOW_ID}"
  
  endpoint = "#{LANGFLOW_URL}/api/v1/run/#{LANGFLOW_FLOW_ID}"
  
  body = {
    input_value: "Hello, this is a test message from Rails",
    output_type: "chat",
    input_type: "chat"
  }
  
  headers = {
    'Content-Type' => 'application/json',
    'Accept' => 'application/json'
  }
  
  headers['Authorization'] = "Bearer #{LANGFLOW_API_KEY}" if LANGFLOW_API_KEY
  
  begin
    response = HTTParty.post(endpoint, body: body.to_json, headers: headers)
    
    puts "\nResponse Code: #{response.code}"
    puts "Response Body: #{JSON.pretty_generate(response.parsed_response)}"
    
    if response.success?
      puts "\n✅ Langflow connection successful!"
    else
      puts "\n❌ Langflow connection failed!"
    end
    
  rescue => e
    puts "\n❌ Error connecting to Langflow: #{e.message}"
  end
end

# Run the test
test_langflow_connection 