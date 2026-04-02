// Web Worker that fires reliable timers even when the main tab is backgrounded.
// Chrome throttles setInterval in background tabs but Workers are exempt.

const timers = new Map();
let nextId = 1;

self.onmessage = (e) => {
  const { type, id, interval } = e.data;
  if (type === "start") {
    const tid = nextId++;
    const iid = setInterval(() => self.postMessage({ id: tid }), interval);
    timers.set(tid, iid);
    self.postMessage({ id: tid, type: "started" });
  } else if (type === "stop") {
    const iid = timers.get(id);
    if (iid != null) {
      clearInterval(iid);
      timers.delete(id);
    }
  } else if (type === "stopAll") {
    timers.forEach((iid) => clearInterval(iid));
    timers.clear();
  }
};
