class UswFanFix < Formula
  desc "USW-Enterprise-8-PoE fan controller fix service"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  version "1.3.0"
  license "MIT"

  # No source to download - this is a service wrapper
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  def install
    (etc/"usw-fan-fix").mkpath

    # Config file for switch IP and fan speed
    config_file = etc/"usw-fan-fix/config"
    config_file.write "SWITCH_IP=192.168.1.24\nFAN_PERCENT=50\n" unless config_file.exist?

    # Fan fix script to deploy to switch
    (etc/"usw-fan-fix/fan-fix.sh").write <<~EOS
      #!/bin/sh
      # ADT7475 Fan Controller
      # Usage: fan-fix.sh [0-100]
      P=${1:-50}
      V=$((P*255/100))
      H=$(printf 0x%02x $V)
      i2cset -y 7 0x2e 0x30 $H
      i2cset -y 7 0x2e 0x44 $H
      i2cset -y 7 0x2e 0x46 $H
    EOS

    # Main service script
    (bin/"usw-fan-fix").write <<~EOS
      #!/bin/bash
      # USW-Enterprise-8-PoE fan controller fix
      # Workaround for Ubiquiti fan duty stuck at 0 bug
      # Chip: ADT7475 at i2c bus 7, address 0x2e

      CONFIG="#{etc}/usw-fan-fix/config"
      FAN_SCRIPT="#{etc}/usw-fan-fix/fan-fix.sh"
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
          cat "$FAN_SCRIPT" | ssh -o BatchMode=yes "$SWITCH_IP" 'cat > /etc/persistent/fan-fix.sh; chmod +x /etc/persistent/fan-fix.sh'
        fi

        # Ensure rc.ed41 boot hook exists
        if ! ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" 'test -f /etc/rc.d/rc.ed41' 2>/dev/null; then
          log "Restoring /etc/rc.d/rc.ed41 boot hook"
          printf '#!/bin/sh\\n/etc/persistent/fan-fix.sh\\n' | ssh -o BatchMode=yes "$SWITCH_IP" 'cat > /etc/rc.d/rc.ed41; chmod +x /etc/rc.d/rc.ed41'
        fi

        # Apply fan fix now
        ssh -o ConnectTimeout=5 -o BatchMode=yes "$SWITCH_IP" "/etc/persistent/fan-fix.sh $FAN_PERCENT" 2>/dev/null

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
      Configuration:
        #{etc}/usw-fan-fix/config

      Set fan speed (0-100) by editing FAN_PERCENT in the config file.

      Logs:
        #{var}/log/usw-fan-fix.log
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
