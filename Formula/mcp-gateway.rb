class McpGateway < Formula
  desc "Docker MCP Gateway service manager"
  homepage "https://github.com/docker/mcp"
  version "1.0.0"
  license "MIT"

  # No source to download - this is a service wrapper for docker mcp gateway
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  depends_on "docker"

  def install
    # Create a simple script that validates docker is available
    (bin/"mcp-gateway-check").write <<~EOS
      #!/bin/bash
      if ! command -v docker &> /dev/null; then
        echo "Docker is not installed or not in PATH"
        exit 1
      fi
      if ! docker info &> /dev/null; then
        echo "Docker daemon is not running"
        exit 1
      fi
      echo "Docker MCP Gateway ready"
    EOS
    chmod 0755, bin/"mcp-gateway-check"
  end

  def caveats
    <<~EOS
      To set your auth token, edit the plist or set MCP_GATEWAY_AUTH_TOKEN:
        #{etc}/mcp-gateway/token

      The service runs on http://localhost:8080/mcp
    EOS
  end

  service do
    run ["/usr/local/bin/docker", "mcp", "gateway", "run", "--transport", "streamable-http", "--port", "8080"]
    environment_variables PATH: "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin",
                          MCP_GATEWAY_AUTH_TOKEN: "bwzg6aefl5xmx7sexb2jn3aee6ldbpy4q6a78xo2inltt8cafo"
    keep_alive true
    log_path var/"log/mcp-gateway.log"
    error_log_path var/"log/mcp-gateway.log"
  end

  test do
    system "#{bin}/mcp-gateway-check"
  end
end
