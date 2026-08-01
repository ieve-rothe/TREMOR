# TREMOR

Real-time LLM observability & context graph server for EMPAWS.

## Quickstart

```bash
# Build
crystal build src/tremor.cr -o bin/tremor

# Run (auto-detects .empaws_local in target dir)
./bin/tremor --dir ~/repos/adjutant/empaws --port 8080
```

Open `http://127.0.0.1:8080` in your browser.

## Features

- **Ongoing Log Stream**: Live SSE stream of LLM calls, prompts, tool calls, and model reasoning.
- **Beads Thread View**: DAG context graph visualizer with sequence grouping, parent-child links, and token stats.
- **Payload Inspector**: Inspect node message payloads, execution metadata, and tool parameters.
- **Slicing & Search**: Instant filtering by role, status, tool execution, and full-text search.

## Endpoints

| Endpoint | Method | Description |
| :--- | :--- | :--- |
| `/` | `GET` | Web Dashboard |
| `/api/views` | `GET` | Available data sources |
| `/api/thread` | `GET` | Context DAG thread graph |
| `/api/node/:id` | `GET` | Single node payload detail |
| `/api/tail/:view` | `GET` | Real-time SSE event stream |

## License

MIT
