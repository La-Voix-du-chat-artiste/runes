Rails.application.routes.draw do
  root "dashboard#index"

  resources :agents, only: %i[index show], param: :agent_id
  resources :packets, only: %i[index show]
  resources :runs, only: %i[index show], param: :run_id
  get "topology", to: "topology#show", as: :topology
  resources :interactions, only: %i[show], param: :id

  # JSON feed used by the Stimulus poller (?after_id=&agent_id=&kind=&request_id=).
  # /feed/stats was dead (no caller ever fetched it) and has been removed.
  get "feed", to: "packets#feed", as: :feed

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
