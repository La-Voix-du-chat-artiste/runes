require "test_helper"
require "tmpdir"

# Slice 3 / PR-3: with RUNES_OBSERVER_TOKEN set, every non-GET route requires
# the bearer (or Basic) token; GET stays open. Without the env var the app is
# exactly as open as before.
class TokenAuthTest < ActionDispatch::IntegrationTest
  setup do
    @tmp = Dir.mktmpdir("runes-workspace")
    FileUtils.mkdir_p(File.join(@tmp, "docs", "epics"))
    @old_ws = ENV["RUNES_OBSERVER_WORKSPACE"]
    @old_token = ENV["RUNES_OBSERVER_TOKEN"]
    ENV["RUNES_OBSERVER_WORKSPACE"] = @tmp
    MissionStore.reset_cache!
  end

  teardown do
    ENV["RUNES_OBSERVER_WORKSPACE"] = @old_ws
    ENV["RUNES_OBSERVER_TOKEN"] = @old_token
    MissionStore.reset_cache!
    FileUtils.remove_entry(@tmp)
  end

  test "without a token configured, writes are open (backwards compatible)" do
    ENV.delete("RUNES_OBSERVER_TOKEN")

    post plan_epics_path, params: { body: "# Open epic\n\nbody" }
    assert_response :redirect
  end

  test "with a token, POST without credentials is 401 and GET stays open" do
    ENV["RUNES_OBSERVER_TOKEN"] = "s3cret"

    post plan_epics_path, params: { body: "# Nope\n" }
    assert_response :unauthorized
    assert_equal 'Bearer realm="runes-observer"', response.headers["WWW-Authenticate"]

    get plan_path
    assert_response :success

    # an existing write route is gated too
    post ack_alert_path(1)
    assert_response :unauthorized
  end

  test "bearer token authorizes the write" do
    ENV["RUNES_OBSERVER_TOKEN"] = "s3cret"

    post plan_epics_path, params: { body: "# Authorized epic\n\nbody" },
         headers: { "Authorization" => "Bearer s3cret" }
    assert_response :redirect
    assert File.exist?(File.join(@tmp, "docs", "epics", "E-1-authorized-epic.md"))
  end

  test "http basic with the token as password authorizes the write" do
    ENV["RUNES_OBSERVER_TOKEN"] = "s3cret"
    basic = "Basic #{["operator:s3cret"].pack("m0")}"

    post plan_epics_path, params: { body: "# Basic epic\n" },
         headers: { "Authorization" => basic }
    assert_response :redirect
  end

  test "a wrong token is 401" do
    ENV["RUNES_OBSERVER_TOKEN"] = "s3cret"

    post plan_epics_path, params: { body: "# Nope\n" },
         headers: { "Authorization" => "Bearer wrong" }
    assert_response :unauthorized
  end
end
