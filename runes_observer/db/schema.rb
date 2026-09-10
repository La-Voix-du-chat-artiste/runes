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

ActiveRecord::Schema[8.1].define(version: 2026_09_10_080002) do
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
    t.datetime "last_message_at"
    t.integer "packets_dropped", default: 0, null: false
    t.integer "packets_total", default: 0, null: false
    t.integer "port"
    t.datetime "started_at"
    t.datetime "updated_at", null: false
  end

  create_table "packets", force: :cascade do |t|
    t.string "agent_id"
    t.datetime "created_at", null: false
    t.string "event"
    t.string "kind", default: "other", null: false
    t.datetime "occurred_at", null: false
    t.text "payload"
    t.integer "payload_bytes", default: 0, null: false
    t.datetime "received_at", null: false
    t.string "request_id"
    t.boolean "scrubbed", default: false, null: false
    t.string "tool"
    t.string "topic", null: false
    t.boolean "truncated", default: false, null: false
    t.datetime "updated_at", null: false
    t.index ["agent_id", "id"], name: "index_packets_on_agent_id_and_id"
    t.index ["agent_id"], name: "index_packets_on_agent_id"
    t.index ["kind"], name: "index_packets_on_kind"
    t.index ["occurred_at"], name: "index_packets_on_occurred_at"
    t.index ["request_id", "id"], name: "index_packets_on_request_id_and_id"
    t.index ["request_id"], name: "index_packets_on_request_id"
    t.index ["topic"], name: "index_packets_on_topic"
  end
end
