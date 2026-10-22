require "spec_helper"
require "tempfile"
require "securerandom"

RSpec.describe ForgeOpsTracker::EventBuilder do
  let(:configuration) do
    ForgeOpsTracker::Configuration.new.tap do |config|
      config.environment = "production"
      config.release = "abc123"
      config.server_name = "web-1"
      config.app_root = "/app"
    end
  end

  subject(:builder) { described_class.new(configuration) }

  def raise_and_capture
    raise ArgumentError, "boom"
  rescue ArgumentError => e
    e
  end

  it "builds a payload with the exception class, message, and configured metadata" do
    error = raise_and_capture

    payload = builder.build(error, context: { "url" => "https://example.com" })

    expect(payload[:exception_class]).to eq("ArgumentError")
    expect(payload[:message]).to eq("boom")
    expect(payload[:environment]).to eq("production")
    expect(payload[:release]).to eq("abc123")
    expect(payload[:server_name]).to eq("web-1")
    expect(payload[:context]).to eq("url" => "https://example.com")
    expect(payload[:occurred_at]).to be_present_iso8601
    expect(payload[:sdk_name]).to eq("ruby")
  end

  it "parses backtrace lines into file/line/method frames" do
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: [
      "/app/app/models/user.rb:42:in 'call'",
      "/app/vendor/bundle/gems/pg-1.5.4/lib/pg.rb:1:in 'exec'"
    ])

    frames = builder.build(error)[:backtrace]

    expect(frames).to eq([
      { file: "/app/app/models/user.rb", line: 42, method: "call", in_app: true },
      { file: "/app/vendor/bundle/gems/pg-1.5.4/lib/pg.rb", line: 1, method: "exec", in_app: false }
    ])
  end

  it "handles the older `in \`method'` backtrace quoting style too" do
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: [
      "/app/app/models/user.rb:42:in `call'"
    ])

    expect(builder.build(error)[:backtrace].first[:method]).to eq("call")
  end

  it "marks a frame outside app_root as not in-app" do
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: [
      "/usr/local/lib/ruby/3.4.0/net/http.rb:100:in 'request'"
    ])

    expect(builder.build(error)[:backtrace].first[:in_app]).to be false
  end

  it "returns an empty backtrace when there is none" do
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: nil)

    expect(builder.build(error)[:backtrace]).to eq([])
  end

  it "scrubs likely-PII out of the message and context by default" do
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "failed for user@example.com", backtrace: nil)

    payload = builder.build(error, context: { "user" => { "email" => "ada@example.com", "password" => "hunter2" } })

    expect(payload[:message]).to eq("failed for [EMAIL FILTERED]")
    expect(payload[:context]).to eq("user" => { "email" => "[EMAIL FILTERED]", "password" => "[FILTERED]" })
  end

  it "leaves the payload untouched when scrub_pii is disabled" do
    configuration.scrub_pii = false
    error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "failed for user@example.com", backtrace: nil)

    payload = builder.build(error, context: { "email" => "ada@example.com" })

    expect(payload[:message]).to eq("failed for user@example.com")
    expect(payload[:context]).to eq("email" => "ada@example.com")
  end

  it "includes the user when given one, never scrubbed even though it's an email" do
    error = raise_and_capture

    payload = builder.build(error, user: { id: 42, email: "ada@example.com" })

    expect(payload[:user]).to eq(id: 42, email: "ada@example.com")
  end

  it "omits the user key entirely when none was given" do
    error = raise_and_capture

    payload = builder.build(error)

    expect(payload).not_to have_key(:user)
  end

  it "includes breadcrumbs when given some" do
    error = raise_and_capture
    breadcrumbs = [ { category: "query", message: "User Load", level: "info", timestamp: "2026-01-01T00:00:00Z", data: {} } ]

    payload = builder.build(error, breadcrumbs: breadcrumbs)

    expect(payload[:breadcrumbs]).to eq(breadcrumbs)
  end

  it "omits the breadcrumbs key entirely when none was given" do
    error = raise_and_capture

    payload = builder.build(error)

    expect(payload).not_to have_key(:breadcrumbs)
  end

  it "scrubs breadcrumb messages, unlike user, since a breadcrumb isn't a deliberately-structured field" do
    error = raise_and_capture
    breadcrumbs = [
      { category: "console", message: "failed for user@example.com", level: "info", timestamp: "2026-01-01T00:00:00Z", data: {} }
    ]

    payload = builder.build(error, breadcrumbs: breadcrumbs)

    expect(payload[:breadcrumbs].first[:message]).to eq("failed for [EMAIL FILTERED]")
  end

  describe "request fields" do
    let(:trace_id) { "4bf92f3577b34da6a3ce929d0e0e4736" }

    it "includes transaction_name, endpoint, and trace_id as top-level keys when given" do
      payload = builder.build(raise_and_capture, transaction_name: "CheckoutsController#create", endpoint: "POST /checkout", trace_id: trace_id)

      expect(payload[:transaction_name]).to eq("CheckoutsController#create")
      expect(payload[:endpoint]).to eq("POST /checkout")
      expect(payload[:trace_id]).to eq(trace_id)
    end

    it "omits each key entirely when it's nil, e.g. outside a request" do
      payload = builder.build(raise_and_capture, transaction_name: nil, endpoint: nil, trace_id: nil)

      expect(payload).not_to have_key(:transaction_name)
      expect(payload).not_to have_key(:endpoint)
      expect(payload).not_to have_key(:trace_id)
    end

    it "omits only the missing ones when some are given" do
      payload = builder.build(raise_and_capture, trace_id: trace_id)

      expect(payload[:trace_id]).to eq(trace_id)
      expect(payload).not_to have_key(:transaction_name)
      expect(payload).not_to have_key(:endpoint)
    end

    it "never scrubs them, like environment/release: they're structured fields, not free text" do
      payload = builder.build(raise_and_capture, transaction_name: "Users::TokensController#show", endpoint: "GET /u/ada@example.com", trace_id: trace_id)

      expect(payload[:transaction_name]).to eq("Users::TokensController#show")
      expect(payload[:endpoint]).to eq("GET /u/ada@example.com")
      expect(payload[:trace_id]).to eq(trace_id)
    end
  end

  describe "source context capture" do
    def write_source_file(line_count)
      file = Tempfile.new([ "app_file", ".rb" ])
      file.write((1..line_count).map { |n| "line #{n}" }.join("\n"))
      file.flush
      configuration.app_root = File.dirname(file.path)
      file
    end

    def frame_for(file, line)
      error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: [
        "#{file.path}:#{line}:in 'call'"
      ])
      builder.build(error)[:backtrace].first
    end

    it "attaches pre_context/context_line/post_context around an in-app frame's culprit line, by default" do
      file = write_source_file(20)

      frame = frame_for(file, 10)

      expect(frame[:context_line]).to eq("line 10")
      expect(frame[:pre_context]).to eq((5..9).map { |n| "line #{n}" })
      expect(frame[:post_context]).to eq((11..15).map { |n| "line #{n}" })
    ensure
      file.close!
    end

    it "clamps pre_context/post_context at the start and end of the file rather than raising" do
      file = write_source_file(3)

      first_frame = frame_for(file, 1)
      last_frame = frame_for(file, 3)

      expect(first_frame[:pre_context]).to eq([])
      expect(first_frame[:post_context]).to eq(%w[line\ 2 line\ 3])
      expect(last_frame[:pre_context]).to eq(%w[line\ 1 line\ 2])
      expect(last_frame[:post_context]).to eq([])
    ensure
      file.close!
    end

    it "truncates an individual line longer than MAX_CONTEXT_LINE_LENGTH" do
      overlong = "x" * 600
      file = Tempfile.new([ "app_file", ".rb" ])
      file.write(overlong)
      file.flush
      configuration.app_root = File.dirname(file.path)

      frame = frame_for(file, 1)

      expect(frame[:context_line]).to eq("#{"x" * 500}...")
    ensure
      file.close!
    end

    it "never attaches context to a frame outside app_root" do
      file = write_source_file(20)
      configuration.app_root = "/somewhere/else"

      frame = frame_for(file, 10)

      expect(frame).not_to have_key(:context_line)
      expect(frame).not_to have_key(:pre_context)
      expect(frame).not_to have_key(:post_context)
    ensure
      file.close!
    end

    it "leaves a frame untouched, with no file read attempted, when capture_source_context is disabled" do
      configuration.capture_source_context = false
      file = write_source_file(20)
      expect(File).not_to receive(:readlines)

      frame = frame_for(file, 10)

      expect(frame).not_to have_key(:context_line)
    ensure
      file.close!
    end

    it "leaves a frame untouched when the recorded file can't be read" do
      configuration.app_root = "/tmp"
      error = instance_double(StandardError, class: RuntimeError, cause: nil, message: "boom", backtrace: [
        "/tmp/this-file-does-not-exist-#{SecureRandom.hex(4)}.rb:1:in 'call'"
      ])

      frame = builder.build(error)[:backtrace].first

      expect(frame).not_to have_key(:context_line)
    end
  end

  describe "SQL capture" do
    let(:sql_error_class) do
      Class.new(StandardError) do
        attr_reader :sql

        def initialize(message, sql)
          super(message)
          @sql = sql
        end
      end
    end
    let(:error) { sql_error_class.new("PG::Error: boom", "EXEC dbo.sp_refund_order @order_id = 8814, @note = 'a@b.co'") }

    it "sends the procedure name but not the statement by default" do
      payload = builder.build(error)

      expect(payload[:sql_objects]).to eq(operation: "EXEC", procedures: [ "dbo.sp_refund_order" ], relations: [])
      expect(payload).not_to have_key(:sql_statement)
    end

    it "sends the masked statement too once capture_sql_statement is on" do
      configuration.capture_sql_statement = true

      expect(builder.build(error)[:sql_statement]).to eq("EXEC dbo.sp_refund_order @order_id = ?, @note = ?")
    end

    it "sends neither when both are off" do
      configuration.capture_sql_objects = false

      payload = builder.build(error)

      expect(payload).not_to have_key(:sql_objects)
      expect(payload).not_to have_key(:sql_statement)
    end

    it "adds nothing for an error with no SQL behind it" do
      payload = builder.build(raise_and_capture)

      expect(payload).not_to have_key(:sql_objects)
      expect(payload).not_to have_key(:sql_statement)
    end
  end
end

RSpec::Matchers.define :be_present_iso8601 do
  match do |value|
    !value.nil? && Time.iso8601(value).is_a?(Time)
  end
end
