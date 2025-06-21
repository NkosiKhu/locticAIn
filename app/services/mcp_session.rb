class McpSession
  CACHE_PREFIX = 'mcp_session_'.freeze
  DEFAULT_EXPIRY = 1.hour
  
  class << self
    # Create a new MCP session
    def create
      session_id = SecureRandom.uuid
      session_data = {
        created_at: Time.current.iso8601,
        initialized: false,
        protocol_version: nil
      }
      
      Rails.cache.write(cache_key(session_id), session_data, expires_in: DEFAULT_EXPIRY)
      Rails.logger.info "Created MCP session: #{session_id}"
      
      session_id
    end
    
    # Check if session exists
    def exists?(session_id)
      return false if session_id.blank?
      Rails.cache.exist?(cache_key(session_id))
    end
    
    # Get session data
    def get(session_id)
      return nil if session_id.blank?
      Rails.cache.read(cache_key(session_id))
    end
    
    # Update session data
    def update(session_id, data)
      return false unless exists?(session_id)
      
      current_data = get(session_id) || {}
      updated_data = current_data.merge(data)
      
      Rails.cache.write(cache_key(session_id), updated_data, expires_in: DEFAULT_EXPIRY)
      Rails.logger.info "Updated MCP session: #{session_id}"
      
      true
    end
    
    # Mark session as initialized
    def initialize_session(session_id, protocol_version)
      update(session_id, {
        initialized: true,
        protocol_version: protocol_version,
        initialized_at: Time.current.iso8601
      })
    end
    
    # Check if session is initialized
    def initialized?(session_id)
      session_data = get(session_id)
      session_data&.dig(:initialized) || false
    end
    
    # Terminate session
    def terminate(session_id)
      return false if session_id.blank?
      
      if Rails.cache.delete(cache_key(session_id))
        Rails.logger.info "Terminated MCP session: #{session_id}"
        true
      else
        false
      end
    end
    
    # Extend session expiry
    def extend_session(session_id)
      return false unless exists?(session_id)
      
      session_data = get(session_id)
      Rails.cache.write(cache_key(session_id), session_data, expires_in: DEFAULT_EXPIRY)
      
      true
    end
    
    # List all active sessions (for debugging)
    def list_active_sessions
      # This is a simplified implementation - in production you might want
      # to use Redis SCAN or maintain a separate index
      Rails.cache.instance_variable_get(:@data)&.keys&.select { |k| 
        k.to_s.start_with?(CACHE_PREFIX) 
      }&.map { |k| k.to_s.sub(CACHE_PREFIX, '') } || []
    end
    
    private
    
    def cache_key(session_id)
      "#{CACHE_PREFIX}#{session_id}"
    end
  end
end 