#!/bin/sh
# demo/demo.sh — scripted terminal demo recorded with asciinema.
# Re-record with:
#   asciinema rec --overwrite --window-size 110x28 --idle-time-limit 2 \
#     -t "truebrew: install ffmpeg with mise, no Homebrew" \
#     -c ./demo/demo.sh demo/truebrew-ffmpeg.cast
set -u

# Neutral environment: this machine's global/project configs reference tools
# that are irrelevant to the demo (their "missing:" warnings would only add
# noise, so point XDG config at an empty dir and work from /tmp).
export XDG_CONFIG_HOME=/tmp/truebrew-demo-xdg
mkdir -p "$XDG_CONFIG_HOME"
cd /tmp

unset TRUEBREW_ROOT
rm -f /tmp/truebrew-demo.mp4

echo '$ mise plugin install --force truebrew https://github.com/matixlol/mise-truebrew'
mise plugin install --force truebrew https://github.com/matixlol/mise-truebrew
echo
sleep 1

echo '$ mise ls-remote truebrew:ffmpeg'
mise ls-remote truebrew:ffmpeg
echo
sleep 1

echo "$ mise install 'truebrew:ffmpeg@latest'"
mise install 'truebrew:ffmpeg@latest'
echo
sleep 1

echo "$ mise exec 'truebrew:ffmpeg@latest' -- ffmpeg -hide_banner -version | head -n 10"
mise exec 'truebrew:ffmpeg@latest' -- ffmpeg -hide_banner -version | head -n 10
echo
sleep 1

echo '$ ffmpeg transcodes with its brewed deps (libx264):'
mise exec 'truebrew:ffmpeg@latest' -- ffmpeg -hide_banner -loglevel error -y -f lavfi -i testsrc=duration=2:size=320x240:rate=10 -c:v libx264 -pix_fmt yuv420p /tmp/truebrew-demo.mp4 && ls -l /tmp/truebrew-demo.mp4
