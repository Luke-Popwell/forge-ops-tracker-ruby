module ForgeOpsTracker
  # Finds the SQL behind a database error and reduces it to something safe to send: the names of
  # the stored procedures, tables and views it touched, and (only if configuration.
  # capture_sql_statement is on) the statement itself with every string and number replaced by
  # "?". Ported from the server's own SqlStatementMasker/SqlObjectExtractor, same rules; the
  # server applies them again on arrival, so a difference here can only ever mean less is
  # masked client-side, never that something unmasked gets stored.
  #
  # Deliberately a single pass over a few patterns, not a SQL parser; see the server's own
  # comments for the reasoning behind each choice, which apply unchanged here.
  module SqlStatement
    MASK = "?".freeze
    MAX_LENGTH = 4_000
    MAX_NAMES = 10
    MAX_NAME_LENGTH = 200
    MAX_CAUSE_DEPTH = 5

    # db.system values where "double quotes" are a string, not a name.
    DOUBLE_QUOTED_STRING_SYSTEMS = %w[mysql mariadb].freeze

    # The prefix only counts as one when it isn't the end of a word, but the quote always does:
    # LIKE'%x%', with no space, is still a string. A backslash can be the statement's last character
    # ('secret\ cut off mid-escape), and the string is still masked to the end.
    STRING = /(?:(?<![\w$])(?:[EeXxNnBb]|[Uu]&))?'(?:[^'\\]|\\(?:.|\z)|'')*(?:'|\z)/m
    DOUBLE_QUOTED_STRING = /"(?:[^"\\]|\\(?:.|\z)|"")*(?:"|\z)/m
    DOLLAR_QUOTED = /(?<tag>\$[A-Za-z_]*\$).*?(?:\k<tag>|\z)/m
    NUMBER = /(?<![\w$.])(?:0[xX]\h+|0[bB][01]+|(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?)(?!\w)/

    LITERAL = Regexp.union(STRING, DOLLAR_QUOTED, NUMBER)
    LITERAL_WITH_DOUBLE_QUOTES = Regexp.union(STRING, DOUBLE_QUOTED_STRING, DOLLAR_QUOTED, NUMBER)

    PART = /(?:[\w$#@]+|"[^"]+"|\[[^\]]+\]|`[^`]+`)/
    NAME = /#{PART}(?:\.#{PART})*/
    OPERATIONS = %w[SELECT INSERT UPDATE DELETE MERGE WITH CALL EXEC EXECUTE CREATE ALTER DROP TRUNCATE].freeze
    PROCEDURE_CALL = /\b(?:CALL|EXEC(?:UTE)?|PERFORM)\s+(?!IMMEDIATE\b|FUNCTION\b|PROCEDURE\b)(#{NAME})/i
    RELATION = /\b(FROM|JOIN|INTO|UPDATE|TABLE)\s+(#{NAME})(\s*\()?/i
    SELECT_FUNCTION = /\A\s*SELECT\s+(#{NAME})\s*\(/i
    BUILTINS = %w[
      count sum min max avg now coalesce nullif lower upper length concat cast date_trunc
      current_timestamp current_date row_number rank json_build_object json_agg array_agg
    ].freeze
    FROM_INSIDE_FUNCTION = /\b(?:EXTRACT|SUBSTRING|TRIM|OVERLAY)\s*\([^()]*\)/i
    KEYWORDS_NOT_NAMES = %w[select set values where lateral only unnest generate_series].freeze

    module_function

    # The raw statement off the error itself or, for an app that wraps a database error in its
    # own exception, off whatever it was raised from. ActiveRecord::StatementInvalid#sql is the
    # one source this reads; nothing else in Ruby exposes the statement on the exception.
    def find_in(error)
      depth = 0
      while error && depth < MAX_CAUSE_DEPTH
        sql = error.sql if error.respond_to?(:sql)
        return sql.to_s if sql.is_a?(String) && !sql.strip.empty?

        error = error.cause
        depth += 1
      end
      nil
    end

    # system is the query's db.system, when known: on MySQL and MariaDB "double quotes" are a
    # string too, so they're masked there and left alone everywhere else.
    def mask(statement, system: nil)
      return nil if statement.nil? || statement.strip.empty?

      pattern = DOUBLE_QUOTED_STRING_SYSTEMS.include?(system.to_s.downcase) ? LITERAL_WITH_DOUBLE_QUOTES : LITERAL
      masked = statement.gsub(pattern, MASK)
      masked.length > MAX_LENGTH ? "#{masked[0, MAX_LENGTH]}..." : masked
    end

    # Takes an already-masked statement (so a keyword inside a string value can't be mistaken for
    # SQL). Returns nil when nothing recognizable was found.
    def objects(masked)
      return nil if masked.nil? || masked.strip.empty?

      sql = masked.gsub(FROM_INSIDE_FUNCTION, " ")
      procedures = sql.scan(PROCEDURE_CALL).flatten
      relations = []

      sql.scan(RELATION) do |keyword, name, paren|
        next if KEYWORDS_NOT_NAMES.include?(name.downcase)

        function_call = paren && %w[FROM JOIN].include?(keyword.upcase)
        (function_call ? procedures : relations) << name
      end

      function = sql[SELECT_FUNCTION, 1]
      procedures << function if function && !BUILTINS.include?(function.downcase) && !sql.match?(/\bFROM\b/i)

      operation = sql[/\A\s*(\w+)/, 1].to_s.upcase
      result = {
        operation: (operation if OPERATIONS.include?(operation)),
        procedures: clean(procedures),
        relations: clean(relations)
      }.compact
      result[:procedures].empty? && result[:relations].empty? && !result.key?(:operation) ? nil : result
    end

    def clean(names)
      names.map { |name| name.to_s.strip[0, MAX_NAME_LENGTH] }
           .select { |name| name.match?(/\A#{NAME}\z/) }
           .uniq.first(MAX_NAMES)
    end
  end
end
