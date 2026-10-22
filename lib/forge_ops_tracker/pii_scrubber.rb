module ForgeOpsTracker
  # Redacts likely-sensitive content out of a payload before it ever leaves
  # this process; the same patterns ForgeOps itself applies again on
  # arrival (defense in depth: this layer keeps the data off the wire and
  # out of any request logging in between; the server-side layer is what
  # actually protects the database, and doesn't depend on every reporting
  # app running an up-to-date version of this gem). See the main
  # application's PiiScrubber for the shared design rationale; kept as a
  # separate, dependency-free implementation here rather than requiring the
  # private app's code, since this gem has to work standalone in any host
  # app regardless of what's reporting into it.
  #
  # Can be turned off via configuration.scrub_pii = false for a host app
  # that already scrubs its own data before it ever reaches error context,
  # or that has its own reasons to want the raw payload. Off by default is
  # not an option: the safe default has to be "on."
  module PiiScrubber
    REDACTED = "[FILTERED]"

    SENSITIVE_KEYS = %w[
      password passwd pwd
      secret apisecret clientsecret secretkey
      token accesstoken refreshtoken apikey apitoken authorization authtoken bearer sessiontoken csrftoken
      creditcard cardnumber cardnum cvv cvv2 cvc
      ssn socialsecuritynumber socialsecurity
      privatekey
    ].freeze

    PATTERNS = {
      "EMAIL" => /[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/,
      "SSN" => /\b\d{3}-\d{2}-\d{4}\b/,
      "CREDIT CARD" => /\b\d{4}[ -]\d{4}[ -]\d{4}[ -]\d{1,4}\b/,
      "BEARER TOKEN" => %r{\bBearer\s+[A-Za-z0-9\-._~+/]+=*}i,
      "JWT" => /\bey[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/,
      "AWS KEY" => /\bAKIA[0-9A-Z]{16}\b/,
      "STRIPE KEY" => /\b[sr]k_(?:live|test)_[A-Za-z0-9]{10,}\b/,
      "GITHUB TOKEN" => /\bgh[pousr]_[A-Za-z0-9]{20,}\b/
    }.freeze

    def self.scrub(value, key: nil)
      if sensitive_key?(key) && !value.nil?
        REDACTED
      else
        case value
        when Hash
          value.each_with_object({}) { |(k, v), out| out[k] = scrub(v, key: k) }
        when Array
          value.map { |v| scrub(v, key: key) }
        when String
          scrub_string(value)
        else
          value
        end
      end
    end

    def self.sensitive_key?(key)
      return false if key.nil?

      normalized = key.to_s.downcase.gsub(/[^a-z0-9]/, "")
      SENSITIVE_KEYS.any? { |sensitive| normalized.include?(sensitive) }
    end
    private_class_method :sensitive_key?

    def self.scrub_string(string)
      PATTERNS.reduce(string) { |scrubbed, (label, pattern)| scrubbed.gsub(pattern, "[#{label} FILTERED]") }
    end
    private_class_method :scrub_string
  end
end
