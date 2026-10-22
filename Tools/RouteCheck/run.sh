#!/bin/zsh
# Objective routing check without listening (SPEC §14).
# Routes a test process that plays a near-silent tone (-60 dBFS) to a device through the running
# SoundLanes app, then reads the app's own measurements via `soundlanes status`:
# route phase, matched process count, tapped input level, and output-device IO cycles.
# It does not prove what you hear; it proves the app's audio reaches the tap and the target device runs IO.
# usage: Tools/RouteCheck/run.sh [deviceUID]   (default: BuiltInSpeakerDevice)
set -euo pipefail
cd "${0:A:h}/../.."
out=build/routecheck; mkdir -p $out
swiftc -O Tools/RouteCheck/tone-player.swift -o $out/tone-player 2>/dev/null \
  -Xlinker -sectcreate -Xlinker __TEXT -Xlinker __info_plist -Xlinker Tools/RouteCheck/Info-tonetest.plist
cli=.build/debug/soundlanes
device=${1:-BuiltInSpeakerDevice}
app=com.zinu.soundlanes.tonetest

check() {  # $1 = label
  $out/tone-player 1.5 4 1000 0.001 &
  local player=$!
  sleep 3
  local first=$($cli status | awk -v app=$app '$1 == app')
  sleep 1.5
  local second=$($cli status | awk -v app=$app '$1 == app')
  wait $player
  echo "$1"
  echo "  $first"
  echo "  $second"
}

$cli add $app $device >/dev/null
check "[S1] 테스트 프로세스 → $device"
check "[S3] 프로세스를 다시 실행"
sleep 1
echo "[대기] 프로세스 종료 후: $($cli status | awk -v app=$app '$1 == app')"
$cli remove $app >/dev/null
