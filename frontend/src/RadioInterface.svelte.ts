import { Configuration } from './Configuration.svelte';

/******************************************************************************/
/* Constants */
/******************************************************************************/

export const AUDIO_AGC_PRESETS: string[] = ['Slow', 'Medium', 'Fast'];

export const AUDIO_BANDWIDTHS: number[] = [6000, 5000, 4000, 3000, 2000, 1000];

export enum ScanBand {
  AM_ITU_1_3,
  AM_ITU_2,
  SW_120M,
  SW_90M,
  SW_75M,
  SW_60M,
  SW_49M,
  SW_41M,
  SW_31M,
  SW_25M,
  SW_22M,
  SW_19M,
  SW_16M,
  SW_15M,
  SW_13M,
  SW_11M,
  TIME,
}

export const SCAN_BANDS: { [key in keyof typeof ScanBand]: ScanBandInfo } = {
  AM_ITU_1_3: { description: 'AM ITU 1,3 (531 - 1602 kHz, step 9 kHz)', sweeps: [{ start: 531e3, stop: 1602e3, step: 9e3 }] },
  AM_ITU_2: { description: 'AM ITU 2 (530 - 1700 kHz, step 10 kHz)', sweeps: [{ start: 530e3, stop: 1700e3, step: 10e3 }] },
  SW_120M: { description: 'SW 120m (2300 - 2495 kHz, step 5 kHz)', sweeps: [{ start: 2300e3, stop: 2495e3, step: 5e3 }] },
  SW_90M: { description: 'SW 90m (3200 - 3400 kHz, step 5 kHz)', sweeps: [{ start: 3200e3, stop: 3400e3, step: 5e3 }] },
  SW_75M: { description: 'SW 75m (3900 - 4000 kHz, step 5 kHz)', sweeps: [{ start: 3900e3, stop: 4000e3, step: 5e3 }] },
  SW_60M: { description: 'SW 60m (4750 - 4995 kHz, step 5 kHz)', sweeps: [{ start: 4750e3, stop: 4995e3, step: 5e3 }] },
  SW_49M: { description: 'SW 49m (5900 - 6200 kHz, step 5 kHz)', sweeps: [{ start: 5900e3, stop: 6200e3, step: 5e3 }] },
  SW_41M: { description: 'SW 41m (7200 - 7450 kHz, step 5 kHz)', sweeps: [{ start: 7200e3, stop: 7450e3, step: 5e3 }] },
  SW_31M: { description: 'SW 31m (9400 - 9900 kHz, step 5 kHz)', sweeps: [{ start: 9400e3, stop: 9900e3, step: 5e3 }] },
  SW_25M: { description: 'SW 25m (11600 - 12100 kHz, step 5 kHz)', sweeps: [{ start: 11600e3, stop: 12100e3, step: 5e3 }] },
  SW_22M: { description: 'SW 22m (13570 - 13870 kHz, step 5 kHz)', sweeps: [{ start: 13570e3, stop: 13870e3, step: 5e3 }] },
  SW_19M: { description: 'SW 19m (15100 - 15800 kHz, step 5 kHz)', sweeps: [{ start: 15100e3, stop: 15800e3, step: 5e3 }] },
  SW_16M: { description: 'SW 16m (17480 - 17900 kHz, step 5 kHz)', sweeps: [{ start: 17480e3, stop: 17900e3, step: 5e3 }] },
  SW_15M: { description: 'SW 15m (18900 - 19020 kHz, step 5 kHz)', sweeps: [{ start: 18900e3, stop: 19020e3, step: 5e3 }] },
  SW_13M: { description: 'SW 13m (21450 - 21850 kHz, step 5 kHz)', sweeps: [{ start: 21450e3, stop: 21850e3, step: 5e3 }] },
  SW_11M: { description: 'SW 11m (25670 - 26100 kHz, step 5 kHz)', sweeps: [{ start: 25670e3, stop: 26100e3, step: 5e3 }] },
  TIME: {
    description: 'Time Stations (2500, 3330, 4996, 5000, 7850, 9996, 10000, 14670, 14996, 15000, 20000 KHz)',
    sweeps: [
      { start: 2500e3, stop: 2500e3, step: 1 },
      { start: 3330e3, stop: 3330e3, step: 1 },
      { start: 4996e3, stop: 4996e3, step: 1 },
      { start: 5000e3, stop: 5000e3, step: 1 },
      { start: 7850e3, stop: 7850e3, step: 1 },
      { start: 9996e3, stop: 9996e3, step: 1 },
      { start: 10000e3, stop: 10000e3, step: 1 },
      { start: 14670e3, stop: 14670e3, step: 1 },
      { start: 14996e3, stop: 14996e3, step: 1 },
      { start: 15000e3, stop: 15000e3, step: 1 },
      { start: 20000e3, stop: 20000e3, step: 1 },
    ],
  },
};

/******************************************************************************/
/* Types */
/******************************************************************************/

export interface FrequencySweep {
  start: number;
  stop: number;
  step: number;
}

export interface ScanBandInfo {
  description: string;
  sweeps: FrequencySweep[];
}

export interface ScanOptions {
  bands: { [key: string]: boolean };
  threshold: number;
}

export interface ScanResult {
  timestamp: string;
  frequency: number;
  power: number;
}

export interface Bookmark {
  frequency: number;
  label: string;
}

/******************************************************************************/
/* WebSocket Protocol Types */
/******************************************************************************/

interface Response {
  id: number;
  success: boolean;
  message?: string;
}

interface StatusEvent {
  frequency: number;
  power_dbfs: number;
  audio_bandwidth: number;
  audio_agc_mode: { preset?: string; custom?: number };
}

interface ScanEvent {
  frequency: number;
  power_dbfs: number;
  timestamp: number;
}

/******************************************************************************/
/* Radio Interface */
/******************************************************************************/

export class RadioInterface {
  /* Configuration State */
  configuration: Configuration;

  /* Websocket State */
  ws: WebSocket | undefined;
  requestPending: { [index: number]: (resolve: Response) => void } = {};
  requestId: number = 0;

  /* Radio State */
  connected: boolean = $state(false);
  scanning: boolean = $state(false);
  frequency: number | undefined = $state();
  power: number | undefined = $state();
  audioBandwidth: number | undefined = $state();
  audioAgcMode: string | number | undefined = $state();

  /* Scan State */
  scanResults: { [frequency: number]: ScanResult } = $state({});

  /****************************************************************************/
  /* Constructor */
  /****************************************************************************/

  constructor(configuration: Configuration) {
    this.configuration = configuration;
    this.scanResults = Object.fromEntries(configuration.scanResults.map((r) => [r.frequency, r]));
  }

  /****************************************************************************/
  /* Main API */
  /****************************************************************************/

  connect(onAudioData: (samples: Float32Array) => void, onClose: () => void) {
    this.ws = new WebSocket('/ws');
    this.ws.binaryType = 'arraybuffer';
    this.ws.addEventListener('message', (event) => this._onMessage(event, onAudioData));
    this.ws.addEventListener('close', (event) => this._onClose(event, onClose));
    this.connected = true;
  }

  disconnect() {
    if (this.ws) this.ws.close();
  }

  async tune(frequency: number): Promise<void> {
    await this._call('tune', [frequency]);
  }

  async scan(sweeps: FrequencySweep[]): Promise<void> {
    await this._call('scan', [sweeps]);
  }

  async abortScan(): Promise<void> {
    await this._call('abortScan', []);
  }

  async setAudioBandwidth(bandwidth: number): Promise<void> {
    await this._call('setAudioBandwidth', [bandwidth]);
  }

  async setAudioAgcMode(mode: string | number): Promise<void> {
    await this._call('setAudioAgcMode', [typeof mode === 'string' ? { preset: mode } : { custom: mode }]);
  }

  /****************************************************************************/
  /* WebSocket Handlers */
  /****************************************************************************/

  private _onStatusEvent(payload: StatusEvent) {
    // Save scan results on completion
    if (this.scanning === true) {
      this.configuration.scanResults = Object.values(this.scanResults);
      this.configuration.save();
    }

    this.scanning = false;
    this.frequency = payload.frequency;
    this.power = payload.power_dbfs;
    this.audioBandwidth = payload.audio_bandwidth;
    this.audioAgcMode = payload.audio_agc_mode.preset ?? payload.audio_agc_mode.custom;
  }

  private _onScanEvent(payload: ScanEvent) {
    // Clear scan results on start
    if (this.scanning === false) {
      this.scanResults = {};
    }

    this.scanning = true;
    this.frequency = payload.frequency;
    this.power = payload.power_dbfs;
    this.scanResults[payload.frequency] = { timestamp: new Date(payload.timestamp).toISOString(), frequency: payload.frequency, power: payload.power_dbfs };
  }

  private _onMessage(event: MessageEvent, onAudioData: (samples: Float32Array) => void) {
    if (event.data instanceof ArrayBuffer) {
      onAudioData(new Float32Array(event.data));
      return;
    }

    const message = JSON.parse(event.data);

    if (message.id !== undefined && this.requestPending[message.id]) {
      this.requestPending[message.id](message);
      delete this.requestPending[message.id];
    } else if (message.event) {
      if (message.event === 'status') {
        this._onStatusEvent(message.payload);
      } else if (message.event === 'scan') {
        this._onScanEvent(message.payload);
      } else {
        console.warn('Unknown event:', message.event);
      }
    } else {
      console.warn('Unknown message:', message);
    }
  }

  private _onClose(event: CloseEvent, onClose: () => void) {
    this.connected = false;
    this.scanning = false;
    this.frequency = undefined;
    this.power = undefined;
    this.audioBandwidth = undefined;
    this.audioAgcMode = undefined;

    if (event.code !== 1000) onClose();
  }

  private async _call(method: string, params: any[]): Promise<void> {
    if (!this.ws) throw new Error('Not connected');

    const request = { id: this.requestId++, method, params };
    this.ws.send(JSON.stringify(request));

    const response: Response = await new Promise((resolve) => {
      this.requestPending[request.id] = resolve;
    });

    if (!response.success) {
      throw new Error(response.message);
    }
  }
}
