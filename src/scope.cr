require "http/server"
require "option_parser"
require "random/secure"
require "uri"

module Scope
  VERSION = "0.1.0"

  class Server
    @dir : String
    @port : Int32
    @host : String
    @token : String
    @bind_all : Bool

    INDEX_HTML = {{ read_file("#{__DIR__}/static/index.html") }}

    def initialize
      @dir = File.expand_path("~/repos/adjutant/empaws")
      @port = 8080
      @host = "127.0.0.1"
      @bind_all = false
      @token = Random::Secure.hex(16)
    end

    def parse_args(args = ARGV)
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: scope [options]"

        parser.on("-d DIR", "--dir=DIR", "Target EMPAWS base directory to monitor") do |d|
          @dir = File.expand_path(d)
        end

        parser.on("-p PORT", "--port=PORT", "Port to listen on (default: 8080)") do |p|
          @port = p.to_i
        end

        parser.on("--bind-all", "Bind to 0.0.0.0 (WARNING: allows external network access)") do
          @bind_all = true
          @host = "0.0.0.0"
        end

        parser.on("-h", "--help", "Show help") do
          puts parser
          exit
        end
      end
    end

    def run
      if @bind_all
        puts "[SECURITY WARNING] Binding to 0.0.0.0! Network devices can access your logs."
      end

      server = HTTP::Server.new do |context|
        req = context.request
        res = context.response

        # 1. Security Check: Validate Host header (allow localhost or 127.0.0.1)
        host_header = req.headers["Host"]? || ""
        host_name = host_header.split(":").first
        unless host_name == "127.0.0.1" || host_name == "localhost" || @bind_all
          res.status_code = 403
          res.print "403 Forbidden: Invalid Host header"
          next
        end

        # 2. Security Check: Validate Token (query param or X-Scope-Token header)
        uri = URI.parse(req.resource)
        params = HTTP::Params.parse(uri.query || "")
        provided_token = params["token"]? || req.headers["X-Scope-Token"]?

        # Serve static assets or check token
        if uri.path == "/"
          # Auto-inject token into redirect if accessing / without token
          if provided_token != @token
            res.status_code = 302
            res.headers["Location"] = "/?token=#{@token}"
            next
          end

          res.headers["Content-Type"] = "text/html"
          res.print INDEX_HTML
          next
        end

        # Require token for API calls
        if provided_token != @token
          res.status_code = 403
          res.print "403 Forbidden: Invalid or missing token"
          next
        end

        # 3. Handle SSE endpoint for tailing llm_calls
        if uri.path == "/api/tail/llm_calls"
          handle_sse_tail(context, "llm_calls.jsonl")
          next
        end

        res.status_code = 404
        res.print "404 Not Found"
      end

      server.bind_tcp(@host, @port)
      url = "http://127.0.0.1:#{@port}/?token=#{@token}"

      puts "🌌 Scope Observability Server active!"
      puts "Monitoring Directory: #{@dir}"
      puts "Access Dashboard:     #{url}"
      puts "Press Ctrl+C to stop."

      server.listen
    end

    private def handle_sse_tail(context, filename : String)
      res = context.response
      res.headers["Content-Type"] = "text/event-stream"
      res.headers["Cache-Control"] = "no-cache"
      res.headers["Connection"] = "keep-alive"
      res.headers["Access-Control-Allow-Origin"] = "*"

      target_file = File.join(@dir, filename)
      unless File.exists?(target_file)
        alt_file = File.join(@dir, "logs", filename)
        target_file = alt_file if File.exists?(alt_file)
      end

      req = context.request
      params = HTTP::Params.parse(URI.parse(req.resource).query || "")
      from_param = req.headers["Last-Event-ID"]? || params["from"]?
      offset = from_param ? (from_param.to_i64? || 0_i64) : 0_i64

      buffer = ""

      loop do
        break if res.closed?

        begin
          if File.exists?(target_file)
            file_size = File.size(target_file)

            if file_size < offset
              offset = 0_i64
              buffer = ""
            end

            if file_size > offset
              File.open(target_file, "r") do |f|
                f.seek(offset, IO::Seek::Set)
                bytes_to_read = file_size - offset
                chunk = Slice(UInt8).new(bytes_to_read.to_i32)
                f.read_fully(chunk)
                buffer += String.new(chunk)

                lines = buffer.split("\n")
                if buffer.ends_with?("\n")
                  buffer = ""
                else
                  buffer = lines.pop || ""
                end

                lines.each do |line|
                  next if line.strip.empty?
                  res.print "id: #{offset}\n"
                  res.print "data: #{line}\n\n"
                  res.flush
                end

                offset = file_size
              end
            end
          end
        rescue ex
          # Ignore transient errors during live file writes
        end

        sleep 0.5.seconds
      end
    end
  end
end

Scope::Server.new.tap do |s|
  s.parse_args
  s.run
end
