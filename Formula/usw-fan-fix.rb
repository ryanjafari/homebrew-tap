class UswFanFix < Formula
  desc "USW-Enterprise-8-PoE fan controller fix service"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  version "1.0.0"
  license "MIT"

  # No source to download - this is a service wrapper
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  def install
    (etc/"usw-fan-fix").mkpath

    # Config file for switch IP
    config_file = etc/"usw-fan-fix/config"
    config_file.write "SWITCH_IP=192.168.1.24\n" unless config_file.exist?

    # Main service script
    (bin/"usw-fan-fix").write <<~EOS
      #!/bin/bash
      # USW-Enterprise-8-PoE fan controller fix
      # Workaround for Ubiquiti fan duty stuck at 0 bug
      # Switch: 192.168.1.24 (78:45:58:b0:91:2a)

      CONFIG="#{etc}/usw-fan-fix/config"
      LOG="#{var}/log/usw-fan-fix.log"

      source "$CONFIG"

      log() {
        echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG"
      }

      while true; do
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'true' 2>/dev/null; then
          log "ERROR: Switch unreachable"
          sleep 300
          continue
        fi

        # Ensure fan-fix.sh exists on switch
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'test -f /etc/persistent/fan-fix.sh' 2>/dev/null; then
          log "Restoring /etc/persistent/fan-fix.sh"
          ssh -o BatchMode=yes "$SWITCH_IP" 'printf "#!/bin/sh\\ni2cset -y 7 0x2e 0x44 0x80\\ni2cset -y 7 0x2e 0x46 0x80\\n" > /etc/persistent/fan-fix.sh; chmod +x /etc/persistent/fan-fix.sh'
        fi

        # Ensure rc.ed41 boot hook exists
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'test -f /etc/rc.d/rc.ed41' 2>/dev/null; then
          log "Restoring /etc/rc.d/rc.ed41 boot hook"
          ssh -o BatchMode=yes "$SWITCH_IP" 'printf "#!/bin/sh\\n/etc/persistent/fan-fix.sh\\nmkdir -p /etc/crontabs\\necho \\"* * * * * /etc/persistent/fan-fix.sh\\" > /etc/crontabs/root\\n" > /etc/rc.d/rc.ed41; chmod +x /etc/rc.d/rc.ed41'
        fi

        # Ensure crontab is active
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'test -f /etc/crontabs/root' 2>/dev/null; then
          log "Restoring crontab"
          ssh -o BatchMode=yes "$SWITCH_IP" 'mkdir -p /etc/crontabs; echo "* * * * * /etc/persistent/fan-fix.sh" > /etc/crontabs/root'
        fi

        # Apply fan fix now
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" '/etc/persistent/fan-fix.sh' 2>/dev/null

        # Get current status
        STATUS=$(ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'swctrl env show' 2>/dev/null)
        TEMP=$(echo "$STATUS" | grep 'General Temperature')
        FAN=$(echo "$STATUS" | grep 'FAN1')
        log "OK — $TEMP | $FAN"

        sleep 300
      done
    EOS
    chmod 0755, bin/"usw-fan-fix"
  end

  def caveats
    <<~EOS
      Switch IP is configured in:
        #{etc}/usw-fan-fix/config

      Logs are at:
        #{var}/log/usw-fan-fix.log

      Ensure SSH key auth is set up for the switch:
        ssh-copy-id #{etc}/usw-fan-fix/config
    EOS
  end

  service do
    run [opt_bin/"usw-fan-fix"]
    keep_alive true
    log_path var/"log/usw-fan-fix.log"
    error_log_path var/"log/usw-fan-fix.log"
  end

  test do
    system "true"
  end
end
