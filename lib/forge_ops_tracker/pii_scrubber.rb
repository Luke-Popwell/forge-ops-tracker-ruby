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
      iban accountnumber routingnumber bankaccount
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

    # Card numbers in any other shape, and IBANs: see sdks/PII_SCRUBBING.md, which every SDK follows,
    # and sdks/pii_scrubbing_vectors.json (a copy is in spec/fixtures), which pins the results.
    DIGIT_RUN = /(?<![A-Za-z0-9_])\d(?:[ -]?\d)*(?![A-Za-z0-9_])/
    CARD_PREFIXES = /\A(?:4|5[1-5]|2(?:22[1-9]|2[3-9]\d|[3-6]\d\d|7[01]\d|720)|3[47]|6011|64[4-9]|65|35(?:2[89]|[3-8]\d)|36|30[0-5]|62)/
    IBAN = /(?<![A-Za-z0-9_])[A-Z]{2}[0-9]{2}(?:[A-Z0-9]{11,30}|(?: [A-Z0-9]{4}){2,7}(?: [A-Z0-9]{1,4})?)(?![A-Za-z0-9_])/

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
      # IBANs first: a spaced IBAN's middle groups look like a formatted card number.
      scrubbed = string.gsub(IBAN) { |candidate| iban?(candidate) ? "[IBAN FILTERED]" : candidate }
      scrubbed = PATTERNS.reduce(scrubbed) { |text, (label, pattern)| text.gsub(pattern, "[#{label} FILTERED]") }
      scrubbed.gsub(DIGIT_RUN) { |run| scrub_card_numbers_in(run) }
    end
    private_class_method :scrub_string

    # From each group of the run on, the longest stretch of whole groups that is a card number is
    # replaced, so a card followed by its CVV, two cards in a row, and Amex's 4-6-5 are all found.
    def self.scrub_card_numbers_in(run)
      groups = run.split(/([ -])/)
      digits = groups.each_slice(2).map(&:first)
      separators = groups.each_slice(2).map { |pair| pair[1] }
      out = +""
      i = 0
      while i < digits.length
        j = (digits.length - 1).downto(i).find { |last| card_number?(digits[i..last].join) }
        if j
          out << "[CREDIT CARD FILTERED]" << separators[j].to_s
          i = j + 1
        else
          out << digits[i] << separators[i].to_s
          i += 1
        end
      end
      out
    end
    private_class_method :scrub_card_numbers_in

    def self.card_number?(digits)
      digits.length.between?(13, 19) && digits.match?(CARD_PREFIXES) && luhn?(digits)
    end
    private_class_method :card_number?

    def self.luhn?(digits)
      sum = digits.reverse.each_char.with_index.sum do |char, index|
        value = char.to_i
        next value if index.even?

        doubled = value * 2
        doubled > 9 ? doubled - 9 : doubled
      end
      (sum % 10).zero?
    end
    private_class_method :luhn?

    # The IBAN check, a digit at a time: the first four characters moved to the end, letters as two
    # digits (A is 10), and the remainder by 97 is 1.
    def self.iban?(candidate)
      compact = candidate.delete(" ")
      return false unless compact.length.between?(15, 34)

      rearranged = compact[4..] + compact[0, 4]
      remainder = rearranged.each_char.reduce(0) do |acc, char|
        (char.match?(/[A-Z]/) ? (char.ord - 55).to_s : char).each_char.reduce(acc) { |r, digit| (r * 10 + digit.to_i) % 97 }
      end
      remainder == 1
    end
    private_class_method :iban?
  end
end
