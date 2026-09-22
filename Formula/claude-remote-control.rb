class ClaudeRemoteControl < Formula
  desc "Always-on Claude Code Remote Control server (shows this Mac in the Claude mobile app)"
  homepage "https://code.claude.com/docs/en/remote-control"
  version "1.0.0"
  license "MIT"

  # No source to download - this is a service wrapper around the claude CLI
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  def install
    (etc/"claude-remote-control").mkpath

    config_file = etc/"claude-remote-control/config"
    config_file.write <<~EOS unless config_file.exist?
      # Directory the server runs from (new sessions from the phone are created here).
      # Must already be trusted: run `claude` there once and accept the trust dialog.
      WORKDIR="$HOME/Documents/Claude/Projects"
      # Name shown in the mobile app's device list.
      NAME="M3 Max"
      # Extra flags for `claude remote-control`, e.g. --permission-mode acceptEdits
      EXTRA_ARGS=""
    EOS

    (bin/"claude-remote-control").write <<~EOS
      #!/bin/bash
      # Runs `claude remote-control` headlessly. Resumes the previous server's
      # sessions when there are any (--continue), otherwise starts fresh.
      export PATH="#{HOMEBREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
      export HOME="${HOME:-/Users/$(id -un)}"
      source "#{etc}/claude-remote-control/config"
      CLAUDE="$(command -v claude)" || { echo "claude CLI not found on PATH" >&2; exit 1; }
      cd "$WORKDIR" || { echo "cannot cd to $WORKDIR" >&2; exit 1; }
      if "$CLAUDE" remote-control --continue --name "$NAME" $EXTRA_ARGS </dev/null; then
        exit 0
      fi
      echo "[$(date)] --continue found nothing to resume, starting a new server" >&2
      exec "$CLAUDE" remote-control --name "$NAME" $EXTRA_ARGS </dev/null
    EOS
    chmod 0755, bin/"claude-remote-control"
  end

  def caveats
    <<~EOS
      Requires the Claude Code CLI (brew install --cask claude-code), logged in
      with a claude.ai account, and the WORKDIR already trusted (run `claude`
      there once). The first run prompts "Enable Remote Control? (y/n)" and
      needs a terminal: run `claude remote-control` once by hand, answer y,
      then Ctrl+C.

      Configuration:
        #{etc}/claude-remote-control/config

      Logs:
        #{var}/log/claude-remote-control.log

      Start with:
        brew services start claude-remote-control
    EOS
  end

  service do
    run ["/usr/bin/caffeinate", "-i", opt_bin/"claude-remote-control"]
    keep_alive true
    environment_variables PATH: std_service_path_env, HOME: Dir.home
    log_path var/"log/claude-remote-control.log"
    error_log_path var/"log/claude-remote-control.log"
  end

  test do
    assert_predicate bin/"claude-remote-control", :executable?
  end
end
