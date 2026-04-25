#!/bin/bash
# HTML → PDF converter using Google Chrome headless mode
# Run from this directory: ./generate.sh

set -e
CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [ ! -x "$CHROME" ]; then
    echo "Error: Google Chrome not found at $CHROME"
    echo "Install Google Chrome or edit CHROME variable in this script."
    exit 1
fi

DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

for html in *.html; do
    pdf="${html%.html}.pdf"
    echo "Converting $html → $pdf"
    "$CHROME" --headless --disable-gpu --no-pdf-header-footer \
        --print-to-pdf="$DIR/$pdf" "file://$DIR/$html" 2>/dev/null
done

echo ""
echo "Generated PDFs:"
ls -lh *.pdf
