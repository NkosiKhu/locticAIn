Rails.application.routes.draw do
  resources :clients
  resources :services
  resources :bookings
  
  # Twilio ConversationRelay webhook
  post '/voice', to: 'voice#voice'
  post '/sms', to: 'voice#voice'  # Some Twilio configs try SMS endpoint too
  
  # MCP Streamable HTTP Transport - Single endpoint for all MCP communication
  match '/mcp', to: 'mcp#handle_mcp', via: [:get, :post, :head, :options, :delete]

  # Mount ActionCable server for WebSocket connections
  mount ActionCable.server => '/cable'

  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  # Render dynamic PWA files from app/views/pwa/* (remember to link manifest in application.html.erb)
  # get "manifest" => "rails/pwa#manifest", as: :pwa_manifest
  # get "service-worker" => "rails/pwa#service_worker", as: :pwa_service_worker

  # Defines the root path route ("/")
  root "home#index"
end
