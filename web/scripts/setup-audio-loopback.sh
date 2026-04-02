#!/bin/bash
# Sets up a Multi-Output Device (current output + BlackHole) so the web app
# can capture all system audio via BlackHole while you still hear everything.
#
# Run once after installing BlackHole and rebooting.
# Usage: ./setup-audio-loopback.sh

set -e

echo "=== NoteAI Audio Loopback Setup ==="
echo ""

# Check BlackHole is available
if ! SwitchAudioSource -a | grep -q "BlackHole 2ch"; then
  echo "ERROR: BlackHole 2ch not found. Did you reboot after installing?"
  echo "  brew install blackhole-2ch && reboot"
  exit 1
fi

echo "BlackHole 2ch detected."
echo ""
echo "Now open Audio MIDI Setup to create a Multi-Output Device:"
echo ""
echo "  1. Open: /Applications/Utilities/Audio MIDI Setup.app"
echo "  2. Click '+' (bottom left) > 'Create Multi-Output Device'"
echo "  3. Check your speakers/AirPods AND 'BlackHole 2ch'"
echo "  4. Make sure your speakers/AirPods is listed FIRST (drag to reorder)"
echo "  5. Right-click the Multi-Output Device > 'Use This Device For Sound Output'"
echo ""
echo "After that, NoteAI web app will automatically detect BlackHole and use it."
echo ""

# Open Audio MIDI Setup for the user
open "/Applications/Utilities/Audio MIDI Setup.app"
