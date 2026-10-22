require "spec_helper"

RSpec.describe ForgeOpsTracker::SqlStatement do
  let(:sql_error_class) do
    Class.new(StandardError) do
      attr_reader :sql

      def initialize(message, sql)
        super(message)
        @sql = sql
      end
    end
  end

  describe ".find_in" do
    it "reads the statement off an error that exposes #sql" do
      expect(described_class.find_in(sql_error_class.new("boom", "SELECT 1"))).to eq("SELECT 1")
    end

    it "walks the cause chain for an app that wrapped the database error" do
      inner = sql_error_class.new("db", "CALL refund_order(1)")
      outer = begin
        begin
          raise inner
        rescue StandardError
          raise ArgumentError, "refund failed"
        end
      rescue ArgumentError => e
        e
      end

      expect(described_class.find_in(outer)).to eq("CALL refund_order(1)")
    end

    it "returns nil for an error with no SQL behind it" do
      expect(described_class.find_in(ArgumentError.new("nope"))).to be_nil
    end
  end

  describe ".mask" do
    it "replaces strings and numbers, leaving identifiers and placeholders" do
      expect(described_class.mask("SELECT * FROM orders2 WHERE email = 'a@b.co' AND id = 42 AND x = $1"))
        .to eq("SELECT * FROM orders2 WHERE email = ? AND id = ? AND x = $1")
    end

    it "masks an escaped quote, a cut-off string, and a dollar-quoted body" do
      expect(described_class.mask("EXEC sp_x @t = 'it''s'")).to eq("EXEC sp_x @t = ?")
      expect(described_class.mask("SELECT 1 WHERE n = 'oops")).to eq("SELECT ? WHERE n = ?")
      expect(described_class.mask("DO $b$ BEGIN PERFORM 1; END $b$")).to eq("DO ?")
    end

    # The server's canonical masking cases (statement, db.system, expected), copied in whole so every
    # SDK's port is checked against exactly the same set.
    corpus = [
        [ "SELECT * FROM orders WHERE email = 'a@b.co' AND id = 42 LIMIT 10", nil, "SELECT * FROM orders WHERE email = ? AND id = ? LIMIT ?" ],
        [ "EXEC sp_note @text = 'it''s broken'", nil, "EXEC sp_note @text = ?" ],
        [ "SELECT 1 WHERE name = 'unterminated", nil, "SELECT ? WHERE name = ?" ],
        [ "DO $body$ BEGIN PERFORM 1; END $body$", nil, "DO ?" ],
        [ "SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)", nil, "SELECT \"user id\" FROM orders2 WHERE id = $1 AND v = sp_v2(?)" ],
        [ "SELECT price * 1.5 FROM t", nil, "SELECT price * ? FROM t" ],
        [ "SELECT * FROM users WHERE name = E'o\\'brien' AND id = 1", nil, "SELECT * FROM users WHERE name = ? AND id = ?" ],
        [ "SELECT * FROM users WHERE name = 'o\\'brien' AND id = 1", nil, "SELECT * FROM users WHERE name = ? AND id = ?" ],
        [ "SELECT * FROM t WHERE b = X'DEADBEEF' AND s = N'uni' AND u = U&'d\\0061t' AND e = e'x'", nil, "SELECT * FROM t WHERE b = ? AND s = ? AND u = ? AND e = ?" ],
        [ "SELECT * FROM t WHERE a LIKE'%secret%'", nil, "SELECT * FROM t WHERE a LIKE?" ],
        [ "SELECT * FROM t WHERE f = 0x1F AND b = 0b101 AND n = 3e10 AND m = 1.5E-3 AND k = .5", nil, "SELECT * FROM t WHERE f = ? AND b = ? AND n = ? AND m = ? AND k = ?" ],
        [ "SELECT e, t.col, 1e5e FROM t", nil, "SELECT e, t.col, 1e5e FROM t" ],
        [ "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "mysql", "SELECT ? FROM t WHERE token = ?" ],
        [ "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "MariaDB", "SELECT ? FROM t WHERE token = ?" ],
        [ "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", "postgresql", "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"" ],
        [ "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"", nil, "SELECT \"user id\" FROM t WHERE token = \"abc123secret\"" ],
        [ "SELECT * FROM t WHERE a = 'x' AND b = 9", nil, "SELECT * FROM t WHERE a = ? AND b = ?" ],
        [ "SELECT * FROM t WHERE a = ? AND b = ?", nil, "SELECT * FROM t WHERE a = ? AND b = ?" ],
        [ "SELECT * FROM t WHERE path = 'C:\\\\dir\\\\' AND n = 5", nil, "SELECT * FROM t WHERE path = ? AND n = ?" ],
        [ "INSERT INTO t (a, b) VALUES (-5, +3.25e+2)", nil, "INSERT INTO t (a, b) VALUES (-?, +?)" ],
        [ "SELECT * FROM t WHERE a = 'secret\\", nil, "SELECT * FROM t WHERE a = ?" ],
        [ "SELECT * FROM t WHERE a = \"secret\\", "mysql", "SELECT * FROM t WHERE a = ?" ]
    ].freeze

    corpus.each do |statement, system, expected|
      it "masks #{statement.inspect}#{" on #{system}" if system} exactly as the server does" do
        expect(described_class.mask(statement, system: system)).to eq(expected)
        expect(described_class.mask(expected, system: system)).to eq(expected)
      end
    end

    it "truncates a very long statement" do
      expect(described_class.mask("SELECT #{"a, " * 3000} b").length).to eq(described_class::MAX_LENGTH + 3)
    end
  end

  describe ".objects" do
    it "finds a stored procedure, schema included" do
      expect(described_class.objects("EXEC dbo.sp_refund_order @id = ?")).to eq(
        operation: "EXEC", procedures: [ "dbo.sp_refund_order" ], relations: []
      )
    end

    it "finds a view and a joined table, and reads FROM fn(...) as a function" do
      expect(described_class.objects("SELECT * FROM v_totals t JOIN public.customers c ON c.id = t.id")[:relations])
        .to eq([ "v_totals", "public.customers" ])
      expect(described_class.objects("SELECT * FROM get_open_orders(?) o")[:procedures]).to eq([ "get_open_orders" ])
    end

    it "does not read an INSERT column list as a function or a builtin as a stored function" do
      expect(described_class.objects("INSERT INTO audit_log (a) VALUES (?)")[:procedures]).to eq([])
      expect(described_class.objects("SELECT count(*) FROM orders")[:procedures]).to eq([])
    end

    it "returns nil when there is nothing recognizable" do
      expect(described_class.objects("garbage")).to be_nil
    end
  end
end
