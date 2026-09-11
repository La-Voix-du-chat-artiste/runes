# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.1].define(version: 2026_09_10_090004) do
  create_table "agents", force: :cascade do |t|
    t.string "agent_id", null: false
    t.text "card"
    t.datetime "created_at", null: false
    t.datetime "ended_at"
    t.datetime "first_seen_at", null: false
    t.string "kind"
    t.datetime "last_seen_at", null: false
    t.string "name"
    t.integer "packet_count", default: 0, null: false
    t.string "state", default: "unknown", null: false
    t.text "tools"
    t.datetime "updated_at", null: false
    t.string "version"
    t.string "workspace"
    t.index ["agent_id"], name: "index_agents_on_agent_id", unique: true
    t.index ["last_seen_at"], name: "index_agents_on_last_seen_at"
    t.index ["state"], name: "index_agents_on_state"
  end

  create_table "ingest_statuses", force: :cascade do |t|
    t.boolean "connected", default: false, null: false
    t.datetime "created_at", null: false
    t.string "host"
    t.string "last_error"
    t.integer "last_lag_ms"
    t.datetime "last_message_at"
    t.integer "packets_dropped", default: 0, null: false
    t.integer "packets_total", default: 0, null: false
    t.integer "port"
    t.integer "reconnects", default: 0, null: false
    t.datetime "started_at"
    t.string "transport"
    t.datetime "updated_at", null: false
  end

  create_table "packets", force: :cascade do |t|
    t.string "agent_id"
    t.string "correlation_id"
    t.datetime "created_at", null: false
    t.string "event"
    t.string "kind", default: "other", null: false
    t.datetime "occurred_at", null: false
    t.text "payload"
    t.integer "payload_bytes", default: 0, null: false
    t.integer "qos"
    t.datetime "received_at", null: false
    t.string "request_id"
    t.string "response_topic"
    t.boolean "retain"
    t.string "run_id"
    t.boolean "scrubbed", default: false, null: false
    t.string "tool"
    t.string "topic", null: false
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.text "user_properties"
    t.index ["agent_id", "id"], name: "index_packets_on_agent_id_and_id"
    t.index ["agent_id"], name: "index_packets_on_agent_id"
    t.index ["correlation_id"], name: "index_packets_on_correlation_id"
    t.index ["kind"], name: "index_packets_on_kind"
    t.index ["occurred_at"], name: "index_packets_on_occurred_at"
    t.index ["request_id", "id"], name: "index_packets_on_request_id_and_id"
    t.index ["request_id"], name: "index_packets_on_request_id"
    t.index ["run_id"], name: "index_packets_on_run_id"
    t.index ["topic"], name: "index_packets_on_topic"
  end

  create_table "workflow_runs", force: :cascade do |t|
    t.string "agent_id"
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.text "error"
    t.datetime "finished_at"
    t.text "params"
    t.string "run_id", null: false
    t.datetime "started_at"
    t.string "status", default: "running", null: false
    t.integer "step_count", default: 0, null: false
    t.datetime "updated_at", null: false
    t.string "workflow", null: false
    t.index ["run_id"], name: "index_workflow_runs_on_run_id", unique: true
    t.index ["started_at"], name: "index_workflow_runs_on_started_at"
    t.index ["status"], name: "index_workflow_runs_on_status"
    t.index ["workflow"], name: "index_workflow_runs_on_workflow"
  end

  create_table "workflow_steps", force: :cascade do |t|
    t.boolean "async", default: false, null: false
    t.datetime "created_at", null: false
    t.float "duration_ms"
    t.text "error"
    t.datetime "finished_at"
    t.text "input"
    t.string "name"
    t.text "output"
    t.integer "position", default: 0, null: false
    t.string "rune"
    t.string "scope"
    t.datetime "started_at"
    t.string "status", default: "running", null: false
    t.datetime "updated_at", null: false
    t.integer "workflow_run_id", null: false
    t.index ["workflow_run_id", "position"], name: "index_workflow_steps_on_workflow_run_id_and_position"
    t.index ["workflow_run_id"], name: "index_workflow_steps_on_workflow_run_id"
  end

  add_foreign_key "workflow_steps", "workflow_runs"
end
