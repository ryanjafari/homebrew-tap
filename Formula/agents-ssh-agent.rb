class AgentsSshAgent < Formula
  desc "Always-on ssh-agent loaded from a 1Password service account, so SSH works with 1Password locked"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  # No source to download - the script is written out below
  url "file:///dev/null"
  version "1.0.0"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "MIT"

  depends_on :macos

  def install
    # Quoted heredoc: Ruby leaves the script's backslashes and ${...} alone.
    (bin/"agents-ssh-agent").write <<~'EOS'
      #!/bin/bash
      # Always-on ssh-agent for SSH that has to work with 1Password locked (phone sessions,
      # routines): git push and commit signing today. 1Password's own agent only answers while
      # the app is unlocked, and a service account can fetch keys but not sign with them, so
      # this agent fetches the keys once through the service account and holds them in memory.
      # Keys are piped straight into ssh-add and never touch disk. Run by the
      # agents-ssh-agent brew service.
      #
      #   agents-ssh-agent           run the agent (what the service does)
      #   agents-ssh-agent status    list the loaded keys
      #
      # Keys: ~/.config/agents-ssh-agent/keys, one 1Password item ID per line (Agents vault;
      # "#" starts a comment). Service-account token: login Keychain, service
      # op-service-account-ploy-and-crit. Socket: ~/.ssh/agents.sock.

      set -u
      export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      SOCK="${AGENTS_SSH_SOCK:-$HOME/.ssh/agents.sock}"
      KEYS="${AGENTS_SSH_KEYS:-$HOME/.config/agents-ssh-agent/keys}"
      TOKEN_SERVICE="${AGENTS_SSH_TOKEN_SERVICE:-op-service-account-ploy-and-crit}"

      log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

      if [ "${1:-}" = status ]; then
        SSH_AUTH_SOCK="$SOCK" ssh-add -l
        exit
      fi

      load() {
        local token id n=0
        [ -f "$KEYS" ] || { log "no key list at $KEYS"; return 1; }
        token="$(security find-generic-password -s "$TOKEN_SERVICE" -w)" || { log "no service-account token in the Keychain"; return 1; }
        for id in $(sed 's/#.*//' "$KEYS"); do
          OP_SERVICE_ACCOUNT_TOKEN="$token" op read "op://Agents/$id/private key?ssh-format=openssh" |
            SSH_AUTH_SOCK="$SOCK" ssh-add -q - || { log "could not load $id"; return 1; }
          n=$((n + 1))
        done
        [ "$n" -gt 0 ]
      }

      mkdir -p "$(dirname "$SOCK")"
      rm -f "$SOCK"
      /usr/bin/ssh-agent -D -a "$SOCK" >/dev/null & AGENT=$!
      trap 'kill $AGENT 2>/dev/null' EXIT TERM
      for _ in $(seq 50); do [ -S "$SOCK" ] && break; sleep 0.1; done

      # At login the network may not be up yet; keep trying until every key is in.
      until load; do
        SSH_AUTH_SOCK="$SOCK" ssh-add -D -q 2>/dev/null
        log "load failed, retrying in 30 s"
        sleep 30
      done
      log "loaded: $(SSH_AUTH_SOCK="$SOCK" ssh-add -l | awk '{print $2}' | tr '\n' ' ')"
      wait $AGENT
    EOS
    chmod 0755, bin/"agents-ssh-agent"
  end

  def caveats
    <<~EOS
      List the 1Password item IDs (Agents vault) of the keys to load, one per line:
        #{Dir.home}/.config/agents-ssh-agent/keys

      Start it (and at every login):
        brew services start agents-ssh-agent

      Point SSH at it, e.g. in ~/.ssh/config:
        Host github.com
          IdentityAgent ~/.ssh/agents.sock

        agents-ssh-agent status    list the loaded keys

      Log:
        #{var}/log/agents-ssh-agent.log
    EOS
  end

  service do
    run opt_bin/"agents-ssh-agent"
    keep_alive true
    environment_variables PATH: std_service_path_env, HOME: Dir.home
    log_path var/"log/agents-ssh-agent.log"
    error_log_path var/"log/agents-ssh-agent.log"
  end

  test do
    assert_predicate bin/"agents-ssh-agent", :executable?
    system "/bin/bash", "-n", bin/"agents-ssh-agent"
  end
end
