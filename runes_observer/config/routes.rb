Rails.application.routes.draw do
  root "dashboard#index"

  resources :agents, only: %i[index show], param: :agent_id
  resources :packets, only: %i[index show]
  resources :runs, only: %i[index show], param: :run_id
  get "topology", to: "topology#show", as: :topology
  # What was refused, next to the dashboard's "who published what" (doc5.md O2.3).
  get "security", to: "security#show", as: :security
  # The fleet board: planned / working / done, as a Mermaid kanban plus the
  # same data as HTML. `board.mmd` is the artifact an agent can read.
  # `board.mmd` must come BEFORE `board`, or `GET /board.mmd` matches
  # `/board(.:format)` and lands on the HTML action with format=mmd.
  get "board.mmd", to: "board#mmd", as: :board_mmd, format: false
  get "board", to: "board#show", as: :board
  resources :interactions, only: %i[show], param: :id

  # JSON feed used by the Stimulus poller (?after_id=&agent_id=&kind=&request_id=).
  # /feed/stats was dead (no caller ever fetched it) and has been removed.
  get "feed", to: "packets#feed", as: :feed

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
