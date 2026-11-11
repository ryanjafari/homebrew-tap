class Watchers < Formula
  desc "Silent watchers that push to the phone through ntfy only when a check finds something"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  # No source to download - the script is written out below
  url "file:///dev/null"
  version "1.3.0"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "MIT"

  depends_on :macos

  def install
    # Quoted heredoc: Ruby leaves the script's backslashes and ${...} alone.
    (bin/"watchers").write <<~'EOS'
      #!/bin/bash
      # Silent watchers: runs each check in ~/.config/watchers/*.conf when it is due and pushes
      # to the phone and Watch through ntfy only when the check prints an ALERT: or ERROR: line.
      # Nothing happens on an ordinary run. Run every 5 minutes by the watchers brew service.
      #
      #   watchers                    run every watcher that is due
      #   watchers run NAME           run one watcher now, due or not
      #   watchers status             last result of each watcher
      #   watchers send TITLE [BODY]  push anything the same way (BODY "-" reads stdin)
      #   watchers test               send a test push
      #
      # A watcher is one config file, NAME.conf, with key = value lines:
      #   title   = push title (keep it ASCII; ntfy headers)
      #   command = shell command; its last output line starts with OK:, ALERT:, ERROR: or QUIET-ERROR:
      #   every   = minutes between runs (default 30)
      #   alert   = push text on ALERT; {detail} is the rest of the line
      #   error   = push text on ERROR; {detail} is the rest of the line
      #   click   = optional URL the push opens
      # The check decides; this only relays. An ERROR is sent once until the watcher recovers,
      # and a push that fails is retried on the next tick (macOS banner as a fallback).
      #
      # State: ~/.local/state/watchers/NAME.json. The ntfy topic is read from
      # ~/.config/watchers/topic (its own topic since 1.3.0) and never printed.

      set -u
      export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      CONF_DIR="${WATCHERS_CONFIG:-$HOME/.config/watchers}"
      STATE_DIR="${WATCHERS_STATE:-$HOME/.local/state/watchers}"
      TOPIC_FILE="${WATCHERS_TOPIC_FILE:-$HOME/.config/watchers/topic}"
      NTFY="${WATCHERS_NTFY:-https://ntfy.sh}"
      mkdir -p "$STATE_DIR"

      log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

      conf() { # conf FILE KEY
        sed -n "s/^$2[[:space:]]*=[[:space:]]*//p" "$1" | head -n 1
      }

      fill() { # fill TEMPLATE DETAIL: puts DETAIL where the template says {detail}
        case "$1" in
          *"{detail}"*) printf '%s%s%s' "${1%%"{detail}"*}" "$2" "${1#*"{detail}"}" ;;
          "") printf '%s' "$2" ;;
          *) printf '%s' "$1" ;;
        esac
      }

      state() { # state NAME JQ-FILTER
        jq -r "$2 // empty" "$STATE_DIR/$1.json" 2>/dev/null
      }

      save() { # save NAME JQ-FILTER [--arg k v ...]
        local name="$1" filter="$2" file="$STATE_DIR/$1.json"
        shift 2
        [ -s "$file" ] || echo '{}' >"$file"
        jq "$@" "$filter" "$file" >"$file.tmp" && mv "$file.tmp" "$file"
      }

      push() { # push TITLE MESSAGE PRIORITY CLICK
        local topic rc
        topic="$(cat "$TOPIC_FILE" 2>/dev/null)"
        [ -n "$topic" ] || { log "push failed: no ntfy topic in $TOPIC_FILE"; return 1; }
        # curl's own error text is dropped: some of it carries the URL, and the URL holds the topic
        curl -fsS -m 30 -o /dev/null -H "Title: $1" -H "Priority: $3" ${4:+-H "Click: $4"} \
          --data-binary "$2" "$NTFY/$topic" 2>/dev/null
        rc=$?
        [ $rc -eq 0 ] || log "push failed: curl exit $rc"
        return $rc
      }

      banner() { # banner TITLE MESSAGE
        /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
          -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
      }

      notify() { # notify NAME TITLE MESSAGE PRIORITY CLICK
        if push "$2" "$3" "$4" "$5"; then
          save "$1" '.pending = null | .last_push = $m | .last_push_at = ($t|tonumber)' --arg m "$3" --arg t "$(date +%s)"
          log "$1: pushed: $3"
        else
          [ -n "$(state "$1" .pending.message)" ] || banner "$2" "$3 (phone push failed, retrying)"
          save "$1" '.pending = {title: $ti, message: $m, priority: $p, click: $c}' \
            --arg ti "$2" --arg m "$3" --arg p "$4" --arg c "$5"
        fi
      }

      run_one() { # run_one CONF-FILE FORCE
        local f="$1" force="$2" name title cmd every now last out rc line detail
        name="$(basename "$f" .conf)"
        title="$(conf "$f" title)"; title="${title:-$name}"
        cmd="$(conf "$f" command)"
        every="$(conf "$f" every)"; every="${every:-30}"
        now="$(date +%s)"

        # a push that failed last time goes out before anything else
        if [ -n "$(state "$name" .pending.message)" ]; then
          notify "$name" "$(state "$name" .pending.title)" "$(state "$name" .pending.message)" \
            "$(state "$name" .pending.priority)" "$(state "$name" .pending.click)"
        fi

        last="$(state "$name" .last_run)"; last="${last:-0}"
        # 60 s of slack so a 30-minute watcher on a 5-minute tick doesn't slip to 35
        if [ "$force" != 1 ] && [ $((now - last)) -lt $((every * 60 - 60)) ]; then
          return
        fi
        if [ -z "$cmd" ]; then
          line="ERROR: no command in $f"
        else
          out="$(/bin/bash -c "$cmd" 2>&1 </dev/null)"; rc=$?
          line="$(tail -n 1 <<<"$out")"
          case "$line" in
            OK:*|ALERT:*|ERROR:*|QUIET-ERROR:*) ;;
            *) line="ERROR: check failed (exit $rc): $(cut -c1-150 <<<"${line:-no output}")" ;;
          esac
        fi
        save "$name" '.name = $n | .title = $ti | .every = ($e|tonumber) | .last_run = ($t|tonumber) | .line = $l' \
          --arg n "$name" --arg ti "$title" --arg e "$every" --arg t "$now" --arg l "$line"
        log "$name: $line"

        detail="${line#*: }"
        case "$line" in
          ALERT:*)
            save "$name" '.last_alert = $l | .last_alert_at = ($t|tonumber) | .error_sent = null' --arg l "$line" --arg t "$now"
            # urgent is the one ntfy priority iOS shows as Time Sensitive, so it gets through a Focus
            notify "$name" "$title" "$(fill "$(conf "$f" alert)" "$detail")" urgent "$(conf "$f" click)"
            ;;
          ERROR:*)
            # sent once; the same error again stays in the log until the watcher recovers
            if [ "$line" != "$(state "$name" .error_sent)" ]; then
              save "$name" '.error_sent = $l' --arg l "$line"
              notify "$name" "$title" "$(fill "$(conf "$f" error)" "$detail" | cut -c1-200)" default "$(conf "$f" click)"
            fi
            ;;
          OK:*)
            save "$name" '.error_sent = null'
            ;;
        esac
      }

      case "${1:-}" in
        "")
          for f in "$CONF_DIR"/*.conf; do
            [ -e "$f" ] && run_one "$f" 0
          done
          ;;
        run)
          [ -f "$CONF_DIR/${2:-}.conf" ] || { echo "no watcher ${2:-} in $CONF_DIR" >&2; exit 1; }
          run_one "$CONF_DIR/$2.conf" 1
          ;;
        status)
          for f in "$STATE_DIR"/*.json; do
            [ -e "$f" ] && jq -r '[.name, (.last_run | localtime | strftime("%m-%d %H:%M")), .line,
              (if .pending then "PUSH PENDING" else "" end)] | join("  ")' "$f"
          done
          ;;
        send)
          [ -n "${2:-}" ] || { echo "usage: watchers send TITLE [BODY|-]" >&2; exit 1; }
          body="${3:-$2}"
          [ "$body" = "-" ] && body="$(cat)"
          push "$2" "$body" default "" && echo "sent" || exit 1
          ;;
        test)
          push "Watchers" "Test push from the watchers service on $(scutil --get ComputerName 2>/dev/null || hostname)" default "" \
            && echo "sent" || exit 1
          ;;
        *)
          sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'
          exit 1
          ;;
      esac
    EOS
    chmod 0755, bin/"watchers"
  end

  def caveats
    <<~EOS
      Runs every 5 minutes as a brew service; each watcher runs on its own interval:
        brew services start watchers

      One watcher is one file in ~/.config/watchers/NAME.conf:
        title   = Push title
        command = python3 /path/to/check.py
        every   = 30
        alert   = Back in stock ({detail})
        error   = Can't read the store: {detail}
        click   = https://shop.example/item

      The check prints one line starting OK:, ALERT:, ERROR: or QUIET-ERROR:.
      ALERT pushes every time it is printed, as urgent so it gets through a Focus;
      ERROR pushes once until it recovers, at normal priority.
      Put a random ntfy topic in ~/.config/watchers/topic and subscribe to it in the
      ntfy app.

        watchers status             last result of each watcher
        watchers run NAME           run one now
        watchers send TITLE [BODY]  push anything the same way (BODY - reads stdin)
        watchers test               send a test push

      Log:
        #{var}/log/watchers.log
    EOS
  end

  service do
    run opt_bin/"watchers"
    run_type :interval
    interval 300
    environment_variables PATH: std_service_path_env, HOME: Dir.home
    log_path var/"log/watchers.log"
    error_log_path var/"log/watchers.log"
  end

  test do
    assert_predicate bin/"watchers", :executable?
    system "/bin/bash", "-n", bin/"watchers"
  end
end
