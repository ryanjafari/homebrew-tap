class DockerMcp < Formula
  desc "Docker MCP Gateway service manager"
  homepage "https://github.com/docker/mcp"
  version "1.0.2"
  license "MIT"

  # No source to download - this is a service wrapper for docker mcp gateway
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  depends_on "docker"

  def install
    # Create config directory and placeholder token file
    (etc/"docker-mcp").mkpath
    token_file = etc/"docker-mcp/token"
    token_file.write "YOUR_TOKEN_HERE\n" unless token_file.exist?

    # Create wrapper script that reads token from config
    (bin/"docker-mcp").write <<~EOS
      #!/bin/bash
      TOKEN_FILE="#{etc}/docker-mcp/token"
      if [[ -f "$TOKEN_FILE" ]]; then
        export MCP_GATEWAY_AUTH_TOKEN=$(cat "$TOKEN_FILE" | tr -d '\n')
      fi
      exec /usr/local/bin/docker mcp gateway run --transport streamable-http --port 8080 "$@"
    EOS
    chmod 0755, bin/"docker-mcp"

    # Create a check script
    (bin/"docker-mcp-check").write <<~EOS
      #!/bin/bash
      if ! command -v docker &> /dev/null; then
        echo "Docker is not installed or not in PATH"
        exit 1
      fi
      if ! docker info &> /dev/null; then
        echo "Docker daemon is not running"
        exit 1
      fi
      echo "Docker MCP ready"
    EOS
    chmod 0755, bin/"docker-mcp-check"
  end

  def caveats
    <<~EOS
      Set your auth token in:
        #{etc}/docker-mcp/token

      The service runs on http://localhost:8080/mcp
    EOS
  end

  service do
    run [opt_bin/"docker-mcp"]
    environment_variables PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin"
    keep_alive true
    log_path var/"log/docker-mcp.log"
    error_log_path var/"log/docker-mcp.log"
  end

  test do
    system "#{bin}/docker-mcp-check"
  end
end
