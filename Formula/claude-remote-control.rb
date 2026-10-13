class ClaudeRemoteControl < Formula
  desc "Always-on Claude Code Remote Control server (shows this Mac in the Claude mobile app)"
  homepage "https://code.claude.com/docs/en/remote-control"
  version "1.3.0"
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
      # After a CLI upgrade the server restarts itself. Seconds it waits for
      # sessions that are mid-turn to finish first (0 = restart at once).
      RESTART_WAIT=600
    EOS

    # `claude remote-control` has no plain-output mode: it redraws its status
    # block (spinner, capacity, session list) with ANSI cursor codes on every
    # change, which in a log file is millions of repeated lines. This filter
    # keeps the real events and drops the redraws.
    (libexec/"logfilter").write <<~'EOS'
      #!/usr/bin/perl
      # Reads `claude remote-control` output, writes a timestamped event log:
      # - [HH:MM:SS] lines (session failed/completed, errors, shutdown): kept
      # - status line (Connecting/Connected/Reconnecting): kept when the state changes
      # - Capacity N/M: kept when it changes
      # - session list, hints, blank lines: dropped
      # - anything else: kept, minus immediate repeats
      use strict;
      use warnings;
      use POSIX qw(strftime);

      $| = 1;
      # Keep draining until claude closes the pipe, so its shutdown lines land.
      $SIG{$_} = 'IGNORE' for qw(TERM INT HUP);

      my ($state, $capacity, $other) = ('', '', '');
      sub out { print strftime('%Y-%m-%d %H:%M:%S ', localtime), $_[0], "\n" }

      while (my $line = <STDIN>) {
        $line =~ s/\e\]8;;[^\a]*\a//g;        # OSC 8 hyperlinks
        $line =~ s/\e\[[0-9;?]*[A-Za-z]//g;   # cursor moves, clears, colors
        $line =~ s/\r//g;
        chomp $line;
        next if $line =~ /^\s*$/;

        if ($line =~ /^\[\d\d:\d\d:\d\d\]/) {
          out($line);
        } elsif ($line =~ /^(?:Continue coding in |Or ask Claude to work in |space to (?:show|hide) QR code)/) {
          next;
        } elsif ($line =~ /^[^\sA-Za-z0-9]+ (\S.*)$/) {
          # Status line: spinner/check glyph, then the state.
          my $text = $1;
          (my $key = $text) =~ s/ \x{c2}\x{b7} retrying in .*//;
          out($text) if $key ne $state;
          $state = $key;
        } elsif ($line =~ /^\s+Capacity: (\d+\/\d+)/) {
          out("Capacity: $1") if $1 ne $capacity;
          $capacity = $1;
        } elsif ($line =~ /^\s/) {
          next;   # session titles and activity summaries
        } elsif ($line ne $other) {
          out($line);
          $other = $line;
        }
      }
    EOS
    chmod 0755, libexec/"logfilter"

    (bin/"claude-remote-control").write <<~EOS
      #!/bin/bash
      # Runs `claude remote-control` headlessly as a multi-session server so this
      # Mac appears in the Claude mobile app's device list and can spawn sessions.
      export PATH="#{HOMEBREW_PREFIX}/bin:/usr/local/bin:/usr/bin:/bin"
      export HOME="${HOME:-/Users/$(id -un)}"
      source "#{etc}/claude-remote-control/config"
      CLAUDE="$(command -v claude)" || { echo "claude CLI not found on PATH" >&2; exit 1; }
      cd "$WORKDIR" || { echo "cannot cd to $WORKDIR" >&2; exit 1; }

      # Safety net in case a CLI update adds output the filter doesn't know:
      # past 10 MB, keep the last 2000 lines. launchd opens the log O_APPEND,
      # so rewriting it in place is safe.
      LOG="#{var}/log/claude-remote-control.log"
      if [ -f "$LOG" ] && [ "$(stat -f %z "$LOG")" -gt 10485760 ]; then
        tail -n 2000 "$LOG" > "$LOG.tmp" && cat "$LOG.tmp" > "$LOG"
        rm -f "$LOG.tmp"
      fi

      # The server pins the CLI binary it started with and spawns every session
      # from that path. A cask upgrade deletes it, so new sessions fail with
      # "spawn error: ENOENT" until the server restarts. This watcher notices
      # the upgrade and stops the server; launchd's KeepAlive starts it again
      # on the new CLI. Stopping cuts off sessions that are mid-turn, so it
      # waits for them to go idle first, up to RESTART_WAIT seconds. The exec
      # below keeps this shell's PID, so $$ is the server.
      BIN="$(realpath "$CLAUDE")"
      note() { echo "$(date '+%Y-%m-%d %H:%M:%S') [watcher] $*" >> "$LOG"; }
      busy() {
        # Each session is a child of the server and records its state in
        # ~/.claude/sessions/<pid>.json.
        local pid
        for pid in $(pgrep -P $$); do
          grep -Eq '"status" *: *"busy"' "$HOME/.claude/sessions/$pid.json" 2>/dev/null && return 0
        done
        return 1
      }
      note "starting on $BIN"
      (
        while sleep 60; do
          kill -0 $$ 2>/dev/null || exit
          new="$(realpath "$(command -v claude)" 2>/dev/null)"
          { [ -x "$new" ] && [ "$new" != "$BIN" ]; } || continue
          note "CLI changed to $new"
          waited=0
          while busy && [ "$waited" -lt "${RESTART_WAIT:-600}" ]; do
            sleep 15
            waited=$((waited + 15))
          done
          note "restarting on the new CLI (waited ${waited}s for busy sessions)"
          kill -TERM $$
          exit
        done
      ) </dev/null >/dev/null 2>&1 &

      # caffeinate -i blocks idle sleep. It runs here rather than in the service
      # definition so launchd's program is this script, and System Settings >
      # Login Items lists the job as "claude-remote-control", not "caffeinate".
      exec /usr/bin/caffeinate -i "$CLAUDE" remote-control --name "$NAME" $EXTRA_ARGS </dev/null \\
        > >("#{libexec}/logfilter") 2>&1
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

      Logs (status redraws filtered out, events only):
        #{var}/log/claude-remote-control.log

      The server restarts itself after a Claude CLI upgrade, once running
      sessions are idle or RESTART_WAIT seconds (default 600) have passed.

      Start with:
        brew services start claude-remote-control
    EOS
  end

  service do
    run opt_bin/"claude-remote-control"
    keep_alive true
    environment_variables PATH: std_service_path_env, HOME: Dir.home
    log_path var/"log/claude-remote-control.log"
    error_log_path var/"log/claude-remote-control.log"
  end

  test do
    assert_predicate bin/"claude-remote-control", :executable?

    redraw = [
      "\e[6A\e[J\u00b7\u2714\ufe0e\u00b7 Connected \u00b7 Projects \u00b7 HEAD",
      "    Capacity: 1/32 \u00b7 New sessions will be created in the current directory",
      "    \e]8;;https://claude.ai/code/session_x\aM3 Max\e]8;;\a",
      "",
      "Continue coding in the Claude mobile app or https://claude.ai/code",
      "space to show QR code",
    ].map { |l| "#{l}\n" }.join
    input = "#{redraw * 3}[12:00:00] Session completed (5s) cse_x\n#{redraw}"
    output = pipe_output(libexec/"logfilter", input)
    lines = output.lines.map { |l| l.sub(/^\S+ \S+ /, "").chomp }
    assert_equal ["Connected \u00b7 Projects \u00b7 HEAD", "Capacity: 1/32",
                  "[12:00:00] Session completed (5s) cse_x"], lines
  end
end
