export interface CaptureMixGraph {
  context: AudioContext;
  destination: MediaStreamAudioDestinationNode;
  recordStream: MediaStream;
  systemSource: MediaStreamAudioSourceNode;
  microphoneSource: MediaStreamAudioSourceNode | null;
}

export function createCaptureMixGraph(
  context: AudioContext,
  {
    systemStream,
    microphoneStream,
  }: {
    systemStream: MediaStream;
    microphoneStream?: MediaStream | null;
  }
): CaptureMixGraph {
  const destination = context.createMediaStreamDestination();
  const systemSource = context.createMediaStreamSource(systemStream);
  systemSource.connect(destination);

  const graph: CaptureMixGraph = {
    context,
    destination,
    recordStream: destination.stream,
    systemSource,
    microphoneSource: null,
  };

  if (microphoneStream) {
    connectMicrophoneToCaptureMix(graph, microphoneStream);
  }

  return graph;
}

export function connectMicrophoneToCaptureMix(
  graph: CaptureMixGraph,
  microphoneStream: MediaStream
): MediaStreamAudioSourceNode {
  graph.microphoneSource?.disconnect();
  const microphoneSource = graph.context.createMediaStreamSource(microphoneStream);
  microphoneSource.connect(graph.destination);
  graph.microphoneSource = microphoneSource;
  return microphoneSource;
}
