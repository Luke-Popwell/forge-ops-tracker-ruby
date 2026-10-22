require "time"

module ForgeOpsTracker
  # Builds the body for one ForgeOpsTracker.record_change call (POST /api/v1/changes): something
  # that changed in a running system (a feature flag flipped, a config value edited, a migration
  # run by hand), so ForgeOps can line it up against the errors and slowdowns around it.
  module Change
    # The server rejects any other kind outright (422), so an unknown one is sent as "other"
    # rather than dropped: the change still gets recorded, just less specifically categorized.
    KINDS = %w[feature_flag config migration dependency infrastructure other].freeze
    MAX_TITLE_LENGTH = 200

    module_function

    # Returns nil when there's nothing sendable (a blank title): the server requires one, so
    # posting it anyway would only ever come back 422.
    def build(configuration, kind:, title:, details: {}, environment: nil, service: nil, actor: nil, url: nil, id: nil, occurred_at: nil)
      title = title.to_s.strip
      return nil if title.empty?

      {
        kind: normalize_kind(kind),
        title: title[0, MAX_TITLE_LENGTH],
        details: details.is_a?(Hash) ? details : {},
        environment: (environment || configuration.environment)&.to_s,
        service: service&.to_s,
        actor: actor&.to_s,
        url: url&.to_s,
        id: id&.to_s,
        occurred_at: iso8601(occurred_at || Time.now)
      }.compact
    end

    def normalize_kind(kind)
      kind = kind.to_s
      KINDS.include?(kind) ? kind : "other"
    end

    def iso8601(value)
      case value
      when Time then value.utc.iso8601(3)
      when String then value
      else value.respond_to?(:to_time) ? value.to_time.utc.iso8601(3) : Time.now.utc.iso8601(3)
      end
    end
  end
end
