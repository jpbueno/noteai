import assert from "node:assert/strict";
import test from "node:test";

import {
  MicrophoneStartupError,
  acquireMicrophoneStream,
  canContinueWithoutMicrophone,
  formatMicrophoneStartupError,
} from "./src/lib/microphone-startup.ts";

function namedError(name, message) {
  const error = new Error(message);
  error.name = name;
  return error;
}

function audioInput(label = "Built-in Microphone") {
  return {
    kind: "audioinput",
    deviceId: label.toLowerCase().replace(/\s+/g, "-"),
    label,
  };
}

function mediaStream() {
  return {
    getTracks() {
      return [{ stop() {} }];
    },
  };
}

test("microphone acquisition retries when a refreshed page briefly sees no microphones", async () => {
  const stream = mediaStream();
  const waits = [];
  const constraints = [];
  let getUserMediaCalls = 0;
  let enumerateCalls = 0;
  const mediaDevices = {
    async getUserMedia(constraint) {
      getUserMediaCalls += 1;
      constraints.push(constraint);
      if (getUserMediaCalls <= 3) {
        throw namedError("NotFoundError", "Requested device not found");
      }
      return stream;
    },
    async enumerateDevices() {
      enumerateCalls += 1;
      return enumerateCalls === 1 ? [] : [audioInput()];
    },
  };

  const result = await acquireMicrophoneStream(mediaDevices, {
    maxNoDeviceRetries: 1,
    retryDelayMs: 5,
    wait: async (ms) => {
      waits.push(ms);
    },
  });

  assert.equal(result.stream, stream);
  assert.equal(getUserMediaCalls, 4);
  assert.deepEqual(waits, [5]);
  assert.deepEqual(constraints[0], { audio: true });
  assert.equal(result.devices.length, 1);
});

test("microphone acquisition does not retry denied permission", async () => {
  let getUserMediaCalls = 0;
  const mediaDevices = {
    async getUserMedia() {
      getUserMediaCalls += 1;
      throw namedError("NotAllowedError", "Permission denied");
    },
    async enumerateDevices() {
      throw new Error("should not enumerate after denied permission");
    },
  };

  await assert.rejects(
    acquireMicrophoneStream(mediaDevices, {
      maxNoDeviceRetries: 3,
      retryDelayMs: 1,
      wait: async () => {},
    }),
    (error) => error instanceof MicrophoneStartupError && error.kind === "permission-denied"
  );

  assert.equal(getUserMediaCalls, 1);
});

test("no-microphone startup message avoids restart-only guidance", () => {
  const message = formatMicrophoneStartupError(
    new MicrophoneStartupError("no-devices", "No microphones detected", {
      devices: [],
      cause: namedError("NotFoundError", "Requested device not found"),
    })
  );

  assert.match(message, /couldn't see a microphone/i);
  assert.match(message, /try Start Recording again/i);
  assert.doesNotMatch(message, /quit chrome|relaunch chrome|restart chrome/i);
});

test("tab capture may continue when Chrome temporarily cannot enumerate microphones", () => {
  const noDevices = new MicrophoneStartupError("no-devices", "No microphones detected");
  const accessFailed = new MicrophoneStartupError("access-failed", "Mic access failed", {
    devices: [audioInput()],
  });

  assert.equal(canContinueWithoutMicrophone(noDevices, true), true);
  assert.equal(canContinueWithoutMicrophone(accessFailed, true), true);
  assert.equal(canContinueWithoutMicrophone(noDevices, false), false);
});

test("tab capture does not continue after explicit microphone permission denial", () => {
  const denied = new MicrophoneStartupError("permission-denied", "Permission denied");

  assert.equal(canContinueWithoutMicrophone(denied, true), false);
});
