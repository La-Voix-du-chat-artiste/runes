Rails.application.routes.draw do
  # The workspace shell (docs/WORKSPACE_PLAN.md slice 1): one page with the
  # live feed, the board, the agents and the runs. The dashboard stays
  # reachable at /dashboard.
  root "workspace#index"
  get "dashboard", to: "dashboard#index", as: :dashboard

  resources :agents, only: %i[index show], param: :agent_id
  resources :packets, only: %i[index show]
  resources :runs, only: %i[index show], param: :run_id
  get "topology", to: "topology#show", as: :topology
  # O1.6: the plugin/rune catalog, generated from the registry.
  get "plugins", to: "plugins#index", as: :plugins
  # O1.5: alerts — list plus the one operator write (ack).
  get "alerts", to: "alerts#index", as: :alerts
  post "alerts/:id/ack", to: "alerts#ack", as: :ack_alert
  # What was refused, next to the dashboard's "who published what" (doc5.md O2.3).
  get "security", to: "security#show", as: :security
  # The fleet board: planned / working / done, as a Mermaid kanban plus the
  # same data as HTML. `board.mmd` is the artifact an agent can read.
  # `board.mmd` must come BEFORE `board`, or `GET /board.mmd` matches
  # `/board(.:format)` and lands on the HTML action with format=mmd.
  get "board.mmd", to: "board#mmd", as: :board_mmd, format: false
  get "board", to: "board#show", as: :board
  resources :interactions, only: %i[show], param: :id

  # Workspace slice 2A: content-addressed documents. The serve route must
  # keep `format: false` so `/documents/<sha>.md` is not parsed as format=md.
  resources :documents, only: %i[index create]
  get "documents/:sha.:ext", to: "documents#serve", as: :document, format: false

  # Workspace slice 2B: named MQTT connector profiles — probe and activate.
  resources :connectors, only: %i[index new create edit update destroy]
  post "connectors/:id/test", to: "connectors#test", as: :test_connector
  post "connectors/:id/activate", to: "connectors#activate", as: :activate_connector

  # Workspace slice 2C: the plan read view — epics and missions from the
  # workspace docs dir (the files the TUI's /plan writes).
  get "plan", to: "plan#index", as: :plan
  get "plan/missions/:id", to: "plan#show", as: :plan_mission

  # Workspace slice 2D: the theatre — all agents in one live picture — and the
  # /wall kiosk (no nav, meta refresh).
  get "theatre", to: "theatre#show", as: :theatre
  get "wall", to: "theatre#wall", as: :wall

  # JSON feed used by the Stimulus poller (?after_id=&agent_id=&kind=&request_id=).
  # /feed/stats was dead (no caller ever fetched it) and has been removed.
  get "feed", to: "packets#feed", as: :feed

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check
end
