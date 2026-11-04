class Watchers < Formula
  desc "Silent watchers that alert the phone through Reminders only when a check finds something"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  # No source to download - the script is written out below
  url "file:///dev/null"
  version "1.1.0"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "MIT"

  depends_on :macos

  def install
    # Quoted heredoc: Ruby leaves the script's backslashes and ${...} alone.
    (bin/"watchers").write <<~'EOS'
      #!/bin/bash
      # Silent watchers: runs each check in ~/.config/watchers/*.conf when it is due and alerts
      # the phone and Watch through Reminders only when the check prints an ALERT: or ERROR: line.
      # Nothing happens on an ordinary run. Run every 5 minutes by the watchers brew service.
      #
      #   watchers                    run every watcher that is due
      #   watchers run NAME           run one watcher now, due or not
      #   watchers status             last result of each watcher
      #   watchers send TEXT [NOTES]  send any alert the same way (NOTES "-" reads stdin)
      #   watchers test               send a test alert
      #
      # A watcher is one config file, NAME.conf, with key = value lines:
      #   title   = name used in the log
      #   command = shell command; its last output line starts with OK:, ALERT:, ERROR: or QUIET-ERROR:
      #   every   = minutes between runs (default 30)
      #   alert   = alert text on ALERT; {detail} is the rest of the line
      #   error   = alert text on ERROR; {detail} is the rest of the line
      #   click   = optional URL, put in the reminder's notes
      # The check decides; this only relays. An ERROR is sent once until the watcher recovers,
      # and an alert that fails is retried on the next tick (macOS banner as a fallback).
      #
      # An alert is a reminder in the iCloud list "Alerts", due a minute after it is made so it
      # has synced to the phone when it fires (the alert shows only the reminder's text). Each
      # one is deleted two days later, so the list never piles up. State: ~/.local/state/watchers/.

      set -u
      export PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      CONF_DIR="${WATCHERS_CONFIG:-$HOME/.config/watchers}"
      STATE_DIR="${WATCHERS_STATE:-$HOME/.local/state/watchers}"
      LIST="${WATCHERS_LIST:-Alerts}"
      KEEP_DAYS=2
      SENT="$STATE_DIR/reminders.tsv"   # epoch <tab> reminder id, for the cleanup
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

      remind() { # remind TEXT NOTES PRIORITY(high|default): makes the reminder, prints its id
        /usr/bin/osascript - "$LIST" "$1" "$2" "$3" <<'EOF'
      on run argv
        set {listName, theText, theNotes, prio} to argv
        tell application "Reminders"
          if not (exists list listName) then make new list with properties {name:listName}
          set props to {name:theText, remind me date:((current date) + 60)}
          if theNotes is not "" then set props to props & {body:theNotes}
          if prio is "high" then set props to props & {priority:1}
          set r to make new reminder at end of list listName with properties props
          return id of r
        end tell
      end run
      EOF
      }

      send() { # send TEXT NOTES PRIORITY
        local id
        id="$(remind "$1" "$2" "$3" 2>&1)"
        case "$id" in
          x-apple-reminder://*)
            printf '%s\t%s\n' "$(date +%s)" "$id" >>"$SENT"
            return 0
            ;;
        esac
        log "alert failed: $(tr '\n' ' ' <<<"$id" | cut -c1-200)"
        return 1
      }

      cleanup() { # deletes the alerts this made once they are KEEP_DAYS old
        [ -s "$SENT" ] || return 0
        local cutoff old
        cutoff=$(($(date +%s) - KEEP_DAYS * 86400))
        old="$(awk -F'\t' -v c="$cutoff" '$1 < c { print $2 }' "$SENT")"
        [ -n "$old" ] || return 0
        # shellcheck disable=SC2086
        if /usr/bin/osascript - $old >/dev/null 2>&1 <<'EOF'
      on run argv
        tell application "Reminders"
          repeat with anId in argv
            try
              delete reminder id (contents of anId)
            end try
          end repeat
        end tell
      end run
      EOF
        then
          awk -F'\t' -v c="$cutoff" '$1 >= c' "$SENT" >"$SENT.tmp" && mv "$SENT.tmp" "$SENT"
          log "deleted $(wc -l <<<"$old" | tr -d ' ') old alert(s)"
        fi
      }

      banner() { # banner TITLE MESSAGE
        /usr/bin/osascript -e 'on run argv' -e 'display notification (item 2 of argv) with title (item 1 of argv)' \
          -e 'end run' "$1" "$2" >/dev/null 2>&1 || true
      }

      notify() { # notify NAME TEXT NOTES PRIORITY
        if send "$2" "$3" "$4"; then
          save "$1" '.pending = null | .last_sent = $m | .last_sent_at = ($t|tonumber)' --arg m "$2" --arg t "$(date +%s)"
          log "$1: sent: $2"
        else
          [ -n "$(state "$1" .pending.text)" ] || banner "Watchers" "$2 (phone alert failed, retrying)"
          save "$1" '.pending = {text: $m, notes: $n, priority: $p}' --arg m "$2" --arg n "$3" --arg p "$4"
        fi
      }

      run_one() { # run_one CONF-FILE FORCE
        local f="$1" force="$2" name title cmd every now last out rc line detail
        name="$(basename "$f" .conf)"
        title="$(conf "$f" title)"; title="${title:-$name}"
        cmd="$(conf "$f" command)"
        every="$(conf "$f" every)"; every="${every:-30}"
        now="$(date +%s)"

        # an alert that failed last time goes out before anything else
        if [ -n "$(state "$name" .pending.text)" ]; then
          notify "$name" "$(state "$name" .pending.text)" "$(state "$name" .pending.notes)" "$(state "$name" .pending.priority)"
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
            notify "$name" "$(fill "$(conf "$f" alert)" "$detail")" "$(conf "$f" click)" high
            ;;
          ERROR:*)
            # sent once; the same error again stays in the log until the watcher recovers
            if [ "$line" != "$(state "$name" .error_sent)" ]; then
              save "$name" '.error_sent = $l' --arg l "$line"
              notify "$name" "$(fill "$(conf "$f" error)" "$detail" | cut -c1-200)" "$(conf "$f" click)" default
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
          cleanup
          ;;
        run)
          [ -f "$CONF_DIR/${2:-}.conf" ] || { echo "no watcher ${2:-} in $CONF_DIR" >&2; exit 1; }
          run_one "$CONF_DIR/$2.conf" 1
          ;;
        status)
          for f in "$STATE_DIR"/*.json; do
            [ -e "$f" ] && jq -r '[.name, (.last_run | localtime | strftime("%m-%d %H:%M")), .line,
              (if .pending then "ALERT PENDING" else "" end)] | join("  ")' "$f"
          done
          ;;
        send)
          [ -n "${2:-}" ] || { echo "usage: watchers send TEXT [NOTES|-]" >&2; exit 1; }
          notes="${3:-}"
          [ "$notes" = "-" ] && notes="$(cat)"
          send "$2" "$notes" default && echo "sent" || exit 1
          ;;
        test)
          send "Watchers test from $(scutil --get ComputerName 2>/dev/null || hostname)" "" default && echo "sent" || exit 1
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
        title   = Name for the log
        command = python3 /path/to/check.py
        every   = 30
        alert   = Back in stock ({detail})
        error   = Can't read the store: {detail}
        click   = https://shop.example/item

      The check prints one line starting OK:, ALERT:, ERROR: or QUIET-ERROR:.
      ALERT sends every time it is printed; ERROR sends once until it recovers.
      An alert is a reminder in the iCloud list "Alerts" that fires a minute
      later on every device, and is deleted two days after.

        watchers status             last result of each watcher
        watchers run NAME           run one now
        watchers send TEXT [NOTES]  send any alert the same way
        watchers test               send a test alert

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
