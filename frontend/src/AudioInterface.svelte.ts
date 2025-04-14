import { Configuration } from './Configuration.svelte';

import { AudioRingBuffer } from './AudioRingBuffer';

import AudioBufferStreamProcessor from './AudioBufferStreamProcessor?worker&url';

/******************************************************************************/
/* Audio Interface */
/******************************************************************************/

export class AudioInterface {
  readonly AUDIO_SAMPLE_RATE = 48000;

  readonly AUDIO_BUFFER_SIZE = this.AUDIO_SAMPLE_RATE * 2;
  readonly AUDIO_BUFFER_LEVEL_UNDERRUN = 0.25;
  readonly AUDIO_BUFFER_LEVEL_OVERRUN = 1.75;
  readonly AUDIO_BUFFER_MONITOR_INTERVAL_MS = 1000;

  /* Configuration State */
  configuration: Configuration;

  /* Audio Context State */
  audioContext: AudioContext;
  gainNode: GainNode;
  audioBufferStreamNode?: AudioWorkletNode;
  audioRingBuffer?: AudioRingBuffer;

  /* Volume State */
  volume: number = $state(0);
  mute: boolean = $state(false);
  bufferLevel: number = $state(0);

  constructor(configuration: Configuration) {
    this.configuration = configuration;
    this.volume = configuration.volume;

    this.audioContext = new AudioContext({ sampleRate: this.AUDIO_SAMPLE_RATE, latencyHint: 'interactive' });
    this.gainNode = this.audioContext.createGain();
    this.gainNode.connect(this.audioContext.destination);
    this.gainNode.gain.setValueAtTime(this.volume / 100, this.audioContext.currentTime);

    try {
      this.audioRingBuffer = new AudioRingBuffer(new SharedArrayBuffer(this.AUDIO_BUFFER_SIZE), new SharedArrayBuffer(4), new SharedArrayBuffer(4));
    } catch (err) {
      console.error(`Error initializing audio ring buffer: ${(err as Error).message}`);
      return;
    }

    this._init();

    $effect(() => {
      setInterval(() => {
        this.onMonitorBufferLevel();
      }, this.AUDIO_BUFFER_MONITOR_INTERVAL_MS);
    });
  }

  async _init() {
    await this.audioContext.audioWorklet.addModule(AudioBufferStreamProcessor);

    this.audioBufferStreamNode = new AudioWorkletNode(this.audioContext, 'audio-buffer-stream-processor', {
      processorOptions: {
        buffer_sab: this.audioRingBuffer!.buffer.buffer,
        read_index_sab: this.audioRingBuffer!.read_index.buffer,
        write_index_sab: this.audioRingBuffer!.write_index.buffer,
      },
    });

    this.audioBufferStreamNode.connect(this.gainNode);
  }

  setVolume(value: number) {
    if (!this.mute) {
      this.gainNode.gain.linearRampToValueAtTime(value / 100, this.audioContext.currentTime + 0.5);
    }

    this.volume = value;
    this.configuration.volume = value;
    this.configuration.save();
  }

  setMute(muted: boolean) {
    this.gainNode.gain.setValueAtTime(muted ? 0 : this.volume / 100, this.audioContext.currentTime);

    this.mute = muted;
  }

  start() {
    this.audioContext.resume();
  }

  reset() {
    if (this.audioBufferStreamNode) this.audioBufferStreamNode.port.postMessage('reset');
  }

  stop() {
    this.audioContext.suspend();

    this.reset();
  }

  onAudioData(samples: Float32Array) {
    if (!this.audioRingBuffer || this.audioContext.state !== 'running') return;

    if (!this.audioRingBuffer.write(samples)) {
      console.warn('Audio buffer overrun, dropping samples...');
    }
  }

  onMonitorBufferLevel() {
    this.bufferLevel = this.audioRingBuffer!.readAvailable() / (this.audioRingBuffer!.buffer.length / 2);

    /* Rebuffer if audio buffer is close to under-running or over-running */
    if (this.audioContext.state === 'running' && (this.bufferLevel < this.AUDIO_BUFFER_LEVEL_UNDERRUN || this.bufferLevel > this.AUDIO_BUFFER_LEVEL_OVERRUN)) {
      this.reset();
    }
  }
}
