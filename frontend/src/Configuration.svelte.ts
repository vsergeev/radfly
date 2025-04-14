import type { ScanOptions, ScanResult, Bookmark } from './RadioInterface.svelte';

const DEFAULT_CONFIGURATION = {
  volume: 75,
  scan: {
    bands: {
      AM_ITU_1_3: false,
      AM_ITU_2: true,
      SW_120M: true,
      SW_90M: true,
      SW_75M: true,
      SW_60M: true,
      SW_49M: true,
      SW_41M: true,
      SW_31M: true,
      SW_25M: true,
      SW_22M: true,
      SW_19M: true,
      SW_16M: true,
      SW_15M: true,
      SW_13M: true,
      SW_11M: true,
      TIME: true,
    },
    threshold: -50,
  },
};

const DEFAULT_BOOKMARKS = [
  { frequency: 2500e3, label: 'WWV/WWVH' },
  { frequency: 3330e3, label: 'CHU' },
  { frequency: 5000e3, label: 'WWV/WWVH' },
  { frequency: 7850e3, label: 'CHU' },
  { frequency: 10000e3, label: 'WWV/WWVH' },
  { frequency: 15000e3, label: 'WWV/WWVH' },
  { frequency: 14670e3, label: 'CHU' },
];

export class Configuration {
  volume: number = $state(DEFAULT_CONFIGURATION.volume);
  scan: ScanOptions = $state(DEFAULT_CONFIGURATION.scan);
  scanResults: ScanResult[] = $state([]);
  bookmarks: Bookmark[] = $state(DEFAULT_BOOKMARKS);

  constructor() {
    this.load();
  }

  hasBookmark(frequency: number): boolean {
    return this.bookmarks.find((b) => b.frequency === frequency) !== undefined;
  }

  load() {
    let serialized = window.localStorage.getItem('configuration');
    if (serialized) {
      try {
        const deserialized = JSON.parse(serialized);
        this.volume = deserialized.volume ?? this.volume;
        this.scan = deserialized.scan ?? this.scan;
      } catch {
        /* continue */
      }
    }

    serialized = window.localStorage.getItem('scanResults');
    if (serialized) {
      try {
        this.scanResults = JSON.parse(serialized) ?? this.scanResults;
      } catch {
        /* continue */
      }
    }

    serialized = window.localStorage.getItem('bookmarks');
    if (serialized) {
      try {
        this.bookmarks = JSON.parse(serialized) ?? this.bookmarks;
      } catch {
        /* continue */
      }
    }
  }

  save() {
    window.localStorage.setItem(
      'configuration',
      JSON.stringify({
        volume: this.volume,
        scan: this.scan,
      }),
    );
    window.localStorage.setItem('scanResults', JSON.stringify(this.scanResults));
    window.localStorage.setItem('bookmarks', JSON.stringify(this.bookmarks));
  }

  static DEFAULT_CONFIGURATION = DEFAULT_CONFIGURATION;
}
