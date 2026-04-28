import assert from "node:assert/strict";
import test from "node:test";

import {
  connectMicrophoneToCaptureMix,
  createCaptureMixGraph,
} from "./src/lib/audio-mixing.ts";

function mediaStream(label) {
  return { label };
}

function createAudioContextStub() {
  const destinations = [];
  const connections = [];
  return {
    destinations,
    connections,
    context: {
      createMediaStreamDestination() {
        const destination = { stream: mediaStream("mixed-output") };
        destinations.push(destination);
        return destination;
      },
      createMediaStreamSource(stream) {
        return {
          stream,
          connect(target) {
            connections.push({ stream, target });
          },
          disconnect() {},
        };
      },
    },
  };
}

test("capture mixer records from a destination stream when only tab audio is available", () => {
  const systemStream = mediaStream("tab-audio");
  const { context, destinations, connections } = createAudioContextStub();

  const graph = createCaptureMixGraph(context, { systemStream, microphoneStream: null });

  assert.equal(destinations.length, 1);
  assert.equal(graph.recordStream, destinations[0].stream);
  assert.equal(graph.destination, destinations[0]);
  assert.ok(
    connections.some(
      (connection) => connection.stream === systemStream && connection.target === destinations[0],
    ),
  );
});

test("capture mixer attaches a recovered microphone to the original recorder destination", () => {
  const systemStream = mediaStream("tab-audio");
  const recoveredMicrophone = mediaStream("built-in-mic");
  const { context, destinations, connections } = createAudioContextStub();
  const graph = createCaptureMixGraph(context, { systemStream, microphoneStream: null });

  const microphoneSource = connectMicrophoneToCaptureMix(graph, recoveredMicrophone);

  assert.equal(destinations.length, 1);
  assert.equal(graph.microphoneSource, microphoneSource);
  assert.ok(
    connections.some(
      (connection) => connection.stream === recoveredMicrophone && connection.target === destinations[0],
    ),
  );
});
