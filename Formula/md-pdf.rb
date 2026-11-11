class MdPdf < Formula
  desc "Turn a Markdown file into a clean printable PDF (pandoc + WeasyPrint)"
  homepage "https://github.com/ryanjafari/homebrew-tap"
  # No source to download - the script and stylesheet are written out below
  url "file:///dev/null"
  version "1.0.0"
  sha256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
  license "MIT"

  depends_on "pandoc"
  depends_on "weasyprint"

  def install
    # Quoted heredocs: Ruby leaves the script's backslashes and ${...} alone.
    (bin/"md-pdf").write <<~'EOS'
      #!/bin/bash
      # md-pdf: turn a Markdown file into a clean printable PDF (Letter, sans-serif, tables).
      #
      #   md-pdf IN.md                   write IN.pdf next to it
      #   md-pdf IN.md -o OUT.pdf        choose the output
      #   md-pdf IN.md --css EXTRA.css   add a stylesheet after the default (repeatable)
      #   md-pdf IN.md --hard-breaks     keep single line breaks (signature blocks, addresses)
      #   md-pdf IN.md --a4              A4 instead of Letter
      #   md-pdf IN.md --html OUT.html   also keep the HTML that was printed
      #
      # Pandoc turns the Markdown into HTML and WeasyPrint prints it. Headings get ids from
      # their text, so a project stylesheet can target one: h2#signatures { break-before: page; }

      set -euo pipefail
      export PATH="/opt/homebrew/bin:/usr/bin:/bin"
      share="${MD_PDF_SHARE:-/opt/homebrew/opt/md-pdf/share/md-pdf}"

      usage() { sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit "${1:-0}"; }
      abspath() { (cd "$(dirname "$1")" && printf '%s/%s\n' "$(pwd)" "$(basename "$1")"); }

      in=""; out=""; css=(); from="markdown"; page="Letter"; keep_html=""
      while [ $# -gt 0 ]; do
        case "$1" in
          -o|--output) out="$2"; shift 2 ;;
          --css) [ -f "$2" ] || { echo "md-pdf: no stylesheet at $2" >&2; exit 1; }; css+=("$(abspath "$2")"); shift 2 ;;
          --hard-breaks) from="markdown+hard_line_breaks"; shift ;;
          --a4) page="A4"; shift ;;
          --html) keep_html="$2"; shift 2 ;;
          -h|--help) usage 0 ;;
          -*) echo "md-pdf: unknown option $1" >&2; usage 1 ;;
          *) if [ -z "$in" ]; then in="$1"; else echo "md-pdf: one input file at a time" >&2; exit 1; fi; shift ;;
        esac
      done
      [ -n "$in" ] && [ -f "$in" ] || { echo "md-pdf: give a Markdown file" >&2; usage 1; }
      [ -n "$out" ] || out="${in%.*}.pdf"

      title="$(grep -m1 '^# ' "$in" | sed 's/^# //' || true)"
      [ -n "$title" ] || title="$(basename "${in%.*}")"

      tmp="$(mktemp -d)"
      trap 'rm -rf "$tmp"' EXIT
      printf '@page { size: %s; }\n' "$page" > "$tmp/page.css"

      args=(--css "$share/md-pdf.css" --css "$tmp/page.css")
      for c in "${css[@]+"${css[@]}"}"; do args+=(--css "$c"); done

      pandoc "$in" -f "$from" -t html5 -s --embed-resources \
        --resource-path="$(dirname "$(abspath "$in")")" \
        --metadata pagetitle="$title" "${args[@]}" -o "$tmp/doc.html"
      [ -z "$keep_html" ] || cp "$tmp/doc.html" "$keep_html"
      weasyprint -q "$tmp/doc.html" "$out"
      echo "$out"
    EOS
    chmod 0755, bin/"md-pdf"

    (pkgshare/"md-pdf.css").write <<~'EOS'
      /* md-pdf default stylesheet. Add your own with --css; it loads after this one. */
      @page { size: Letter; margin: 0.9in 0.9in 0.8in; }
      html { font-family: "Helvetica Neue", Helvetica, Arial, sans-serif; font-size: 10.5pt; line-height: 1.45; color: #1a1a1a; }
      body { margin: 0; }
      h1 { font-size: 18pt; margin: 0 0 10pt; }
      h2 { font-size: 12pt; margin: 18pt 0 6pt; padding-bottom: 3pt; border-bottom: 1px solid #ccc; break-after: avoid; }
      h3, h4 { font-size: 11pt; margin: 14pt 0 4pt; break-after: avoid; }
      p, li { margin: 0 0 6pt; }
      ul, ol { padding-left: 18pt; margin: 0 0 8pt; }
      table { border-collapse: collapse; width: 100%; margin: 4pt 0 10pt; }
      th, td { text-align: left; vertical-align: top; padding: 4pt 8pt; border-bottom: 1px solid #ddd; }
      th { background: #f3f3f3; }
      code { font-family: Menlo, monospace; font-size: 9.5pt; }
      pre { background: #f6f6f6; padding: 6pt 8pt; white-space: pre-wrap; }
      a { color: inherit; }
      img { max-width: 100%; }
    EOS
  end

  test do
    (testpath/"t.md").write "# Hello\n\n| a | b |\n|---|---|\n| 1 | 2 |\n"
    system bin/"md-pdf", testpath/"t.md"
    assert_path_exists testpath/"t.pdf"
  end
end
