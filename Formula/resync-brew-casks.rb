class ResyncBrewCasks < Formula
  desc "Keep Homebrew's versions current for self-updating apps without quitting them"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  version "1.0.0"
  license "MIT"

  # No source to download - the script is written out below
  url "file:///dev/null"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"

  depends_on :macos

  def install
    (libexec/"resync.py").write <<~'EOS'
      #!/usr/bin/env python3
      """Resync Homebrew's recorded version for casks whose app updated itself.

      Installed by the resync-brew-casks formula (ryanjafari/tap) and run by its brew
      service every 6 hours; output goes to $(brew --prefix)/var/log/resync-brew-casks.log.

      A self-updating app (Claude, Chrome, Signal, 1Password, Taphouse...) moves ahead of the
      version Homebrew recorded at install time, so Taphouse and `brew` show it as outdated.
      Only drift is touched: a cask is resynced when the app on disk already reports the
      cask's current version. An app that has not updated itself yet is left to its own
      updater. Taphouse's weekly auto-upgrade handles everything else, with "Include
      self-updating casks" off so the two never do the same work.

      How: Homebrew adopts the app that is already in place. The old record
      (/opt/homebrew/Caskroom/<cask>) is moved to ~/.claude/backups/brew-adopt/, then
      `brew install --cask --adopt <cask>` writes a fresh record and keeps the installed app
      as it is: for a self-updating cask Homebrew skips its version check and only adds a
      symlink and Finder metadata (Library/Homebrew/cask/artifact/moved.rb). Nothing is quit,
      moved or reinstalled, so the app can be in use, Claude included. If the new record
      doesn't check out, the old one is put back. (`brew upgrade --cask --greedy` would
      reinstall the app and run the cask's quit step, which quits Claude mid-session and
      locks 1Password.)

      Only casks that install nothing but apps are adopted; anything with an installer,
      binaries or other pieces is left alone and reported.

        resync.py            resync drifted casks
        resync.py --dry-run  report only

      Prints one line per finding and ends with a line starting OK:, RESYNCED: or ERROR:.
      """
      import json
      import os
      import shutil
      import subprocess
      import sys
      import time

      BREW = "/opt/homebrew/bin/brew"
      CASKROOM = "/opt/homebrew/Caskroom"
      BACKUPS = os.path.expanduser("~/.claude/backups/brew-adopt")
      KEEP_BACKUPS = 2   # per cask, newest first
      # what a cask may install and still be adopted whole
      ADOPTABLE = {"app", "target", "uninstall", "zap"}
      # Never touched, with the reason shown in the report.
      SKIP = {
          "docker-desktop": "quitting Docker stops running containers",
      }
      ENV = dict(os.environ, HOMEBREW_NO_ENV_HINTS="1", HOMEBREW_NO_INSTALL_CLEANUP="1",
                 PATH="/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin")


      def run(args, timeout=1800):
          return subprocess.run(args, capture_output=True, text=True, timeout=timeout,
                                stdin=subprocess.DEVNULL, env=ENV)


      def brew_json(args):
          r = run([BREW] + args, timeout=300)
          if r.returncode != 0:
              raise RuntimeError(f"brew {' '.join(args)} failed: {r.stderr.strip()[-300:]}")
          return json.loads(r.stdout)


      def plist_value(app_path, key):
          r = run(["/usr/bin/defaults", "read", os.path.join(app_path, "Contents", "Info"), key], timeout=20)
          return r.stdout.strip() if r.returncode == 0 else ""


      def app_paths(cask):
          paths = []
          for artifact in cask["artifacts"]:
              for item in [artifact.get("app")] if "app" in artifact else []:
                  name, target = item[0], None
                  for extra in item[1:]:
                      if isinstance(extra, dict) and "target" in extra:
                          target = extra["target"]
                  if target and target.startswith("/"):
                      paths.append(target)
                  else:
                      paths.append("/Applications/" + os.path.basename(target or name))
          return paths


      def uninstall_keys(cask):
          keys = set()
          for artifact in cask["artifacts"]:
              if "pkg" in artifact or "installer" in artifact:
                  keys.add("pkg")
              for directive in artifact.get("uninstall", []):
                  keys.update(directive.keys())
          return keys


      def on_disk_matches(cask):
          """True when every app of the cask already reports the cask's current version."""
          wanted = cask["version"]
          main = wanted.split(",")[0]
          paths = app_paths(cask)
          if not paths:
              return None
          for p in paths:
              short, build = plist_value(p, "CFBundleShortVersionString"), plist_value(p, "CFBundleVersion")
              if not short and not build:
                  return None
              if main not in (short, build) and wanted != short:
                  return False
          return True


      def adoptable(cask):
          return {k for a in cask["artifacts"] for k in a.keys()} <= ADOPTABLE


      def recorded(token):
          return brew_json(["info", "--cask", "--json=v2", token])["casks"][0].get("installed") or ""


      def prune(token):
          mine = sorted((d for d in os.listdir(BACKUPS) if d.startswith(token + "-")), reverse=True)
          for d in mine[KEEP_BACKUPS:]:
              shutil.rmtree(os.path.join(BACKUPS, d), ignore_errors=True)


      def adopt(token, cask):
          """Re-record a self-updated app without touching it; put the old record back if anything is off."""
          room = os.path.join(CASKROOM, token)
          if not os.path.isdir(room):
              return False, "no Homebrew record to replace"
          os.makedirs(BACKUPS, exist_ok=True)
          backup = os.path.join(BACKUPS, f"{token}-{time.strftime('%Y%m%dT%H%M%S')}")
          shutil.move(room, backup)
          r = run([BREW, "install", "--cask", "--adopt", token])
          tail = " / ".join((r.stdout + r.stderr).strip().splitlines()[-3:])
          try:
              now = recorded(token)
          except Exception as exc:
              now, tail = "", f"{tail} / {exc}"
          if r.returncode == 0 and now == cask["version"] and "Adopting existing" in r.stdout + r.stderr:
              prune(token)
              return True, ""
          if os.path.exists(room):
              shutil.rmtree(room, ignore_errors=True)
          shutil.move(backup, room)
          return False, f"adopt didn't check out, old record restored ({tail})"


      def main():
          dry = "--dry-run" in sys.argv

          outdated = brew_json(["outdated", "--cask", "--greedy-auto-updates", "--json=v2"])["casks"]
          if not outdated:
              print("OK: nothing to resync")
              return
          tokens = [c["name"] for c in outdated]
          info = {c["token"]: c for c in brew_json(["info", "--cask", "--json=v2"] + tokens)["casks"]}

          todo, notes = [], []
          for token in tokens:
              cask = info[token]
              label = f"{token} {(cask.get('installed') or '?').split(',')[0]} -> {cask['version'].split(',')[0]}"
              if token in SKIP:
                  notes.append(f"left alone: {label} ({SKIP[token]})")
              elif "pkg" in uninstall_keys(cask):
                  notes.append(f"left alone: {label} (installer, may ask for a password)")
              elif not cask.get("auto_updates"):
                  notes.append(f"not drift: {label} (an ordinary update, left to Taphouse)")
              elif not adoptable(cask):
                  notes.append(f"left alone: {label} (installs more than an app)")
              else:
                  match = on_disk_matches(cask)
                  if match is None:
                      notes.append(f"left alone: {label} (can't read the installed version)")
                  elif not match:
                      notes.append(f"not drift: {label} (the app hasn't updated itself yet)")
                  else:
                      todo.append((token, label))

          for n in notes:
              print(n)

          done, errors = [], []
          for token, label in todo:
              if dry:
                  print(f"would resync: {label}")
                  continue
              ok, why = adopt(token, info[token])
              (done if ok else errors).append(label if ok else f"{label}: {why}")

          if done:
              print("resynced: " + "; ".join(done))
          if errors:
              print("ERROR: " + "; ".join(errors))
          elif done:
              print("RESYNCED: " + "; ".join(done))
          else:
              print("OK: nothing to resync")


      if __name__ == "__main__":
          try:
              main()
          except Exception as exc:  # the routine reads the last line, so always leave one
              print(f"ERROR: {exc}")
              sys.exit(1)
    EOS

    (bin/"resync-brew-casks").write <<~EOS
      #!/bin/bash
      # One resync pass: runs the script, timestamps its output, and posts a macOS
      # notification when the result (the script's last line) is an ERROR.
      export PATH="#{HOMEBREW_PREFIX}/bin:/usr/bin:/bin:/usr/sbin:/sbin"
      export HOME="${HOME:-/Users/$(id -un)}"
      OUT="$(/usr/bin/python3 "#{libexec}/resync.py" "$@" 2>&1)"
      RC=$?
      printf '%s\n' "$OUT" | while IFS= read -r line; do
        printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$line"
      done
      LAST="$(printf '%s\n' "$OUT" | tail -n 1)"
      case "$LAST" in
        ERROR:*)
          MSG="$(printf '%s' "${LAST#ERROR: }" | cut -c1-200 | tr '"\\' "' ")"
          /usr/bin/osascript -e "display notification \"$MSG\" with title \"Homebrew cask resync failed\"" || true
          ;;
      esac
      exit $RC
    EOS
    chmod 0755, bin/"resync-brew-casks"
  end

  def caveats
    <<~EOS
      Runs every 6 hours as a brew service (and once when it starts):
        brew services start resync-brew-casks

      One pass by hand, or a report of what it would do:
        resync-brew-casks
        resync-brew-casks --dry-run

      Log:
        #{var}/log/resync-brew-casks.log

      Pair it with Taphouse's "Include self-updating casks" switched off, so
      Taphouse's auto-upgrade never reinstalls (and quits) those apps.
    EOS
  end

  service do
    run opt_bin/"resync-brew-casks"
    run_type :interval
    interval 21600
    environment_variables PATH: std_service_path_env, HOME: Dir.home
    log_path var/"log/resync-brew-casks.log"
    error_log_path var/"log/resync-brew-casks.log"
  end

  test do
    assert_predicate bin/"resync-brew-casks", :executable?
    system "/usr/bin/python3", "-m", "py_compile", libexec/"resync.py"
  end
end
