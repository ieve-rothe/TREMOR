require "http/server"
require "option_parser"
require "random/secure"
require "uri"
require "json"

module Tremor
  VERSION = "0.1.0"

  class Server
    @dir : String
    @port : Int32
    @host : String
    @token : String
    @bind_all : Bool

    INDEX_HTML = {{ read_file("#{__DIR__}/static/index.html") }}

    private def expand_dir(path : String) : String
      if path.starts_with?("~")
        home = ENV["HOME"]? || "/home/cam"
        File.expand_path(path.sub(/^~/, home))
      else
        File.expand_path(path)
      end
    end

    def initialize
      @dir = expand_dir("~/repos/adjutant/empaws")
      @port = 8080
      @host = "127.0.0.1"
      @bind_all = false
      @token = Random::Secure.hex(16)
    end

    def parse_args(args = ARGV)
      OptionParser.parse(args) do |parser|
        parser.banner = "Usage: tremor [options]"

        parser.on("-d DIR", "--dir=DIR", "Target EMPAWS base directory to monitor") do |d|
          @dir = expand_dir(d)
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
      @dir = expand_dir(@dir)

      # Auto-detect local data directory if present in target base directory
      empaws_local = File.join(@dir, ".empaws_local")
      sandbox_local = File.join(@dir, "sandbox", "local")
      if File.directory?(empaws_local)
        @dir = empaws_local
      elsif File.directory?(sandbox_local)
        @dir = sandbox_local
      end

      if @bind_all
        puts "[SECURITY WARNING] Binding to 0.0.0.0! Network devices can access your logs."
      end

      server = HTTP::Server.new do |context|
        req = context.request
        res = context.response

        # 1. Security Check: Validate Host header
        host_header = req.headers["Host"]? || ""
        host_name = host_header.split(":").first
        unless host_name == "127.0.0.1" || host_name == "localhost" || @bind_all
          res.status_code = 403
          res.print "403 Forbidden: Invalid Host header"
          next
        end

        # 2. Security Check: Validate Token
        uri = URI.parse(req.resource)
        params = HTTP::Params.parse(uri.query || "")
        provided_token = params["token"]? || req.headers["X-Tremor-Token"]?

        # Serve static asset or check token
        if uri.path == "/"
          if provided_token != @token
            res.status_code = 302
            res.headers["Location"] = "/?token=#{@token}"
            next
          end

          res.headers["Content-Type"] = "text/html"
          res.print INDEX_HTML
          next
        end

        # Serve static files (JS, CSS, etc.) from src/static without token
        if uri.path.ends_with?(".js") || uri.path.ends_with?(".css") || uri.path.starts_with?("/_ds/")
          static_path = File.join(__DIR__, "static", uri.path)
          if File.exists?(static_path) && !File.directory?(static_path)
            content = File.read(static_path)
            res.headers["Content-Type"] = case
              when uri.path.ends_with?(".js") then "application/javascript"
              when uri.path.ends_with?(".css") then "text/css"
              else "application/octet-stream"
            end
            res.print content
            next
          end
        end

        if provided_token != @token
          res.status_code = 403
          res.print "403 Forbidden: Invalid or missing token"
          next
        end

        # 3. API Routing
        case uri.path
        when "/api/views"
          handle_api_views(context)
        when "/api/thread"
          handle_api_thread(context)
        when .starts_with?("/api/tail/")
          view_name = uri.path[10..-1]
          handle_sse_tail(context, view_name)
        when .starts_with?("/api/node/")
          node_id = uri.path[10..-1]
          handle_api_node(context, node_id)
        else
          res.status_code = 404
          res.print "404 Not Found"
        end
      end

      server.bind_tcp(@host, @port)
      url = "http://127.0.0.1:#{@port}/?token=#{@token}"

      puts "🌌 TREMOR Observability Server active!"
      puts "Monitoring Directory: #{@dir}"
      puts "Access Dashboard:     #{url}"
      puts "Press Ctrl+C to stop."

      server.listen
    end

    private def find_target_file(filename : String) : String?
      candidates = [
        File.join(@dir, filename),
        File.join(@dir, "logs", filename),
        File.join(File.dirname(@dir), filename)
      ]
      candidates.find { |path| File.exists?(path) }
    end

    private def handle_api_views(context)
      res = context.response
      res.headers["Content-Type"] = "application/json"

      views = [] of Hash(String, String)
      
      add_view_if_exists(views, "llm_calls", "llm_calls.jsonl", "LLM Calls Stream", "stream")
      add_view_if_exists(views, "app_log", "logs/empaws.log", "Empaws App Log", "stream")
      add_view_if_exists(views, "running_log", "logs/running_log.txt", "Running Log", "stream")

      frames_dir = File.join(@dir, "frames")
      if Dir.exists?(frames_dir)
        Dir.glob(File.join(frames_dir, "*.json")).each do |f|
          name = File.basename(f)
          views << {"id" => "frame:#{name}", "filename" => f, "label" => "Frame: #{name}", "type" => "static"}
        end
      end

      res.print views.to_json
    end

    private def add_view_if_exists(views, id, rel_path, label, type)
      full = find_target_file(rel_path)
      if full
        views << {"id" => id, "filename" => rel_path, "label" => label, "type" => type}
      end
    end

    private def handle_api_thread(context)
      res = context.response
      res.headers["Content-Type"] = "application/json"

      nodes_summary = [] of Hash(String, JSON::Any)
      seen_ids = Set(String).new
      seen_sequence_ids = Set(String).new

      # 1. Active DAG Context Nodes
      # First pass: collect all nodes and build parent chains to derive sequence groups
      all_dag_nodes = [] of {String, JSON::Any}  # {id, node_json}
      context_files = Dir.glob(File.join(@dir, "context", "*.json"))
      context_files.concat(Dir.glob(File.join(@dir, "*.json")))

      context_files.each do |cfile|
        begin
          json_text = File.read(cfile)
          parsed = JSON.parse(json_text)
          if parsed_nodes = parsed["nodes"]?
            parsed_nodes.as_h.each do |id, node|
              next if seen_ids.includes?(id)
              seen_ids.add(id)
              all_dag_nodes << {id, node}
            end
          end
        rescue ex
        end
      end

      # Build parent_id lookup and derive sequence groups from root chains
      parent_map = {} of String => String?
      all_dag_nodes.each do |(id, node)|
        parent_map[id] = node["parent_id"]?.try(&.to_s)
      end

      # Find the root of each node's chain
      node_to_root = {} of String => String
      all_dag_nodes.each do |(id, _)|
        current = id
        while parent = parent_map[current]?
          current = parent
        end
        node_to_root[id] = current
      end

      all_dag_nodes.each do |(id, node)|
        msg = node["message"]?
        role = msg ? (msg["role"]?.try(&.to_s) || "unknown") : "unknown"
        turn_id = node["turn_id"]?.try(&.to_s)
        token_count = node["token_count"]? ? node["token_count"].to_s.to_i? || 0 : 0
        parent_id = node["parent_id"]?.try(&.to_s)
        subsumes = node["subsumes"]? ? node["subsumes"].as_a.map(&.to_s) : [] of String
        has_tools = msg && msg["tool_calls"]? && !msg["tool_calls"].as_a.empty?

        # Use turn_id if set, otherwise derive from root chain
        seq_id = turn_id || node_to_root[id]?

        summary = {
          "id" => JSON::Any.new(id),
          "role" => JSON::Any.new(role),
          "parent_id" => parent_id ? JSON::Any.new(parent_id) : JSON::Any.new(nil),
          "turn_id" => turn_id ? JSON::Any.new(turn_id) : JSON::Any.new(nil),
          "sequence_id" => seq_id ? JSON::Any.new(seq_id) : JSON::Any.new(nil),
          "token_count" => JSON::Any.new(token_count.to_i64),
          "subsumes" => JSON::Any.new(subsumes.map { |s| JSON::Any.new(s) }),
          "has_tools" => JSON::Any.new(has_tools || false)
        }
        nodes_summary << summary
      end

      # Collect all sequence IDs from context nodes so we can skip duplicates from llm_calls
      nodes_summary.each do |ns|
        if sid = ns["sequence_id"]?
          if sid_str = sid.as_s?
            seen_sequence_ids.add(sid_str)
          end
        end
      end

      # 2. Historical Calls from llm_calls.jsonl — skip entries whose sequence_id is already covered
      llm_calls_file = find_target_file("llm_calls.jsonl")
      if llm_calls_file && File.exists?(llm_calls_file)
        begin
          File.each_line(llm_calls_file) do |line|
            next if line.strip.empty?
            parsed = JSON.parse(line)
            id = parsed["id"]?.try(&.to_s) || Random::Secure.hex(8)
            next if seen_ids.includes?(id)

            seq_id = parsed["sequence_id"]?.try(&.to_s)
            # Skip this llm_calls entry if context DAG already has nodes for this sequence
            next if seq_id && seen_sequence_ids.includes?(seq_id)

            seen_ids.add(id)

            raw_out = parsed["raw_output"]?
            has_tools = false
            if raw_out && raw_out["tool_calls"]? && !raw_out["tool_calls"].as_a.empty?
              has_tools = true
            end

            content_text = raw_out ? (raw_out["content"]?.try(&.to_s) || "") : ""
            tokens = (content_text.bytesize / 4).to_i64

            role = has_tools ? "tool" : "assistant"
            summary = {
              "id" => JSON::Any.new(id),
              "role" => JSON::Any.new(role),
              "parent_id" => JSON::Any.new(nil),
              "turn_id" => seq_id ? JSON::Any.new(seq_id) : JSON::Any.new(nil),
              "sequence_id" => seq_id ? JSON::Any.new(seq_id) : JSON::Any.new(nil),
              "token_count" => JSON::Any.new(tokens),
              "subsumes" => JSON::Any.new([] of JSON::Any),
              "has_tools" => JSON::Any.new(has_tools)
            }
            nodes_summary << summary
          end
        rescue ex
        end
      end

      res.print nodes_summary.to_json
    end

    private def handle_api_node(context, node_id : String)
      res = context.response
      res.headers["Content-Type"] = "application/json"

      # 1. Search in DAG context files
      context_files = Dir.glob(File.join(@dir, "context", "*.json"))
      context_files.concat(Dir.glob(File.join(@dir, "*.json")))

      context_files.each do |cfile|
        begin
          json_text = File.read(cfile)
          parsed = JSON.parse(json_text)
          if parsed_nodes = parsed["nodes"]?
            if target_node = parsed_nodes.as_h[node_id]?
              res.print target_node.to_json
              return
            end
          end
        rescue ex
        end
      end

      # 2. Search in llm_calls.jsonl
      llm_calls_file = find_target_file("llm_calls.jsonl")
      if llm_calls_file && File.exists?(llm_calls_file)
        begin
          File.each_line(llm_calls_file) do |line|
            next if line.strip.empty?
            parsed = JSON.parse(line)
            if parsed["id"]?.try(&.to_s) == node_id
              res.print parsed.to_json
              return
            end
          end
        rescue ex
        end
      end

      res.status_code = 404
      res.print({"error" => "Node #{node_id} not found"}.to_json)
    end

    private def handle_sse_tail(context, view_name : String)
      res = context.response
      res.headers["Content-Type"] = "text/event-stream"
      res.headers["Cache-Control"] = "no-cache"
      res.headers["Connection"] = "keep-alive"
      res.headers["Access-Control-Allow-Origin"] = "*"

      filename = view_name == "llm_calls" ? "llm_calls.jsonl" : view_name
      target_file = find_target_file(filename)

      unless target_file && File.exists?(target_file)
        res.status_code = 404
        res.print "event: error\ndata: File #{filename} not found\n\n"
        return
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
        end

        sleep 0.5.seconds
      end
    end
  end
end

Tremor::Server.new.tap do |s|
  s.parse_args
  s.run
end
