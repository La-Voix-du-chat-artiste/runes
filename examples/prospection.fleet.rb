# fleet-spec: 0.1
fleet "prospection" do
  description "CRM pipeline: qualify contacts, draft outreach, review."
  transport :mqtt5
  group "prospection-prompts"
  config env: "staging"

  channel :contact_found,     "runes/events/contacts/found",     schema: :contact
  channel :contact_qualified, "runes/events/contacts/qualified", schema: :contact
  channel :draft_ready,       "runes/events/drafts/ready",       schema: :draft
  channel :metrics,           "runes/events/metrics"
  channel :outbox,            "runes/events/outbox"

  fact :max_drafts_per_hour, 20
  fact :outreach_tone, "professional"

  agent :scraper do
    model "deepseek-flash", variation: :high
    tools fs_read: :allow, exec: { allow: %w[curl jq] }
    workspace "workspace/scraper"
    identity "config/keys/scraper.pem"
    concurrency 2
  end

  agent :writer do
    model "glm-5.3-flash"
    tools fs_write: :allow
  end

  agent :reviewer do
    model "deepseek-flash"
    tools :none
  end

  route :scraper, :writer, :reviewer
  route :reviewer, :outbox, when: :accepted
  route scraper: :metrics
  route :contact_found, :scraper

  on :contact_found do |e|
    next! unless e.email.match?(/\A[^@]+@[^@]+\z/)
    task :scraper, "Enrichis %{email} et publie sur :contact_qualified"
  end

  on :contact_qualified do |e|
    next! unless e.score > 0.7
    task :writer, "Redige l'email pour %{name} (ton: %{outreach_tone})"
    publish :metrics, { kind: "qualified" }
  end

  on :draft_ready, guard: ->(e) { e.risk == "low" } do |e|
    notify "Brouillon pret pour %{contact}", level: :info
  end

  on :guard_denied do |e|
    notify "Refus: %{agent} / %{tool} / %{action}", level: :warn
  end

  on :weekly_report do |e|
    notify "Rapport hebdo pret", level: :info
  end

  schedule :weekly_report, cron: "0 9 * * MON"
end
