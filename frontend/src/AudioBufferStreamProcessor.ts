import { AudioRingBuffer } from './AudioRingBuffer';

export class AudioBufferStreamProcessor extends AudioWorkletProcessor {
  ring_buffer: AudioRingBuffer;
  loaded: boolean = false;

  constructor(options: AudioWorkletNodeOptions) {
    super();

    this.ring_buffer = new AudioRingBuffer(
      options.processorOptions.buffer_sab,
      options.processorOptions.read_index_sab,
      options.processorOptions.write_index_sab,
    );

    this.port.onmessage = (event) => {
      if (event.data === 'reset') {
        this.ring_buffer.reset();
        this.loaded = false;
      }
    };
  }

  process(inputs: Float32Array[][], outputs: Float32Array[][], _: Record<string, Float32Array>): boolean {
    if (!this.loaded) {
      if (this.ring_buffer.readAvailable() < this.ring_buffer.buffer.length / 2) {
        return true;
      }
      this.loaded = true;
    }

    if (!this.ring_buffer.read(outputs[0][0])) {
      console.warn('Audio buffer underrun, skipping samples...');
    }

    return true;
  }
}

registerProcessor('audio-buffer-stream-processor', AudioBufferStreamProcessor);
