<script lang="ts">
  import { Configuration } from './Configuration.svelte';
  import { RadioInterface } from './RadioInterface.svelte';
  import { AudioInterface } from './AudioInterface.svelte';
  import type { ScanResult } from './RadioInterface.svelte';
  import { AUDIO_BANDWIDTHS, AUDIO_AGC_PRESETS, SCAN_BANDS } from './RadioInterface.svelte';
  import type { FrequencySweep } from './RadioInterface.svelte';

  import './app.css';
  import { Toggle, Button, Range, Label, A } from 'flowbite-svelte';
  import { Dropdown, DropdownItem, ButtonGroup } from 'flowbite-svelte';
  import { Tabs, TabItem } from 'flowbite-svelte';
  import { Table, TableHead, TableHeadCell, TableBody, TableBodyRow, TableBodyCell } from 'flowbite-svelte';
  import { DarkMode } from 'flowbite-svelte';

  import InputModal from './InputModal.svelte';
  import ErrorModal from './ErrorModal.svelte';
  import ScanOptionsModal from './ScanOptionsModal.svelte';
  import EditBookmarkModal from './EditBookmarkModal.svelte';

  /****************************************************************************/
  /* State */
  /****************************************************************************/

  let configuration = new Configuration();
  let audio = new AudioInterface(configuration);
  let radio = new RadioInterface(configuration);
  let currentTime = $state(new Date());

  /****************************************************************************/
  /* UI State */
  /****************************************************************************/

  /* Dropdowns */
  let bandwidthDropdownOpen: boolean = $state(false);
  let agcModeDropdownOpen: boolean = $state(false);

  /* Scan Results and Bookmarks */
  let scanResultsSortFn: (a: ScanResult, b: ScanResult) => number = $state((a, b) => a.frequency - b.frequency);
  let bookmarkSelectedIndex: number | undefined = $state(undefined);

  /* Modals */
  let errorModal: ErrorModal;
  let inputModal: InputModal;
  let scanOptionsModal: ScanOptionsModal;
  let editBookmarkModal: EditBookmarkModal;

  /****************************************************************************/
  /* Formatters */
  /****************************************************************************/

  function formatTime(t: Date): string {
    return `${t.toLocaleTimeString(undefined, { timeZoneName: 'short' })} (${t.toLocaleTimeString(undefined, { timeZone: 'UTC', timeZoneName: 'short' })})`;
  }

  function formatFrequency(frequency: number | undefined): string {
    return frequency === undefined ? '---- KHz' : `${Math.floor(frequency / 1e3).toLocaleString()} KHz`;
  }

  function formatPower(power: number | undefined): string {
    return power === undefined ? '- dBFS' : `${power.toFixed(2)} dBFS`;
  }

  function formatBandwidth(bandwidth: number | undefined): string {
    return bandwidth === undefined ? '- KHz' : `${(bandwidth / 1e3).toString()} KHz`;
  }

  function formatAgcMode(agcMode: string | number | undefined): string {
    return agcMode === undefined ? '-' : typeof agcMode === 'string' ? agcMode : `Custom (${agcMode.toFixed(1)} sec)`;
  }

  function formatSignalStrength(power: number): string {
    const scale = -configuration.scan.threshold / 5;
    return Math.max(Math.min(Math.floor(power / scale) + 6, 5), 1).toFixed(0);
  }

  function formatScanOpacity(timestamp: string): string {
    const elapsed = Number(new Date()) - Number(new Date(timestamp));
    return Math.min(Math.max(100 - (elapsed - 3600 * 1000) * (25 / (3600 * 1000)), 50), 100).toFixed(0);
  }

  function formatBufferLevel(level: number): string {
    return `${(level * 100).toFixed(0)}%`;
  }

  /****************************************************************************/
  /* Handlers */
  /****************************************************************************/

  async function handleConnect(event: MouseEvent) {
    if (!radio.connected) {
      if (audio.audioBufferStreamNode === undefined) {
        errorModal.show(`Error initializing audio:`, `radfly must be served from a secure context (HTTPS) for real-time audio support.`);
      }

      try {
        radio.connect((data) => audio.onAudioData(data), handleDisconnect);
      } catch (err) {
        errorModal.show(`Error connecting to radio:`, `${(err as Error).message}`);
      }

      await audio.start();
    } else {
      audio.stop();
      radio.disconnect();
    }

    (event.target as HTMLInputElement).checked = radio.connected;
  }

  async function handleDisconnect() {
    audio.stop();
    errorModal.show(`Connection Failed`);
  }

  function handleToggleFullscreen() {
    if (!document.fullscreenElement) {
      document.documentElement.requestFullscreen();
    } else if (document.exitFullscreen) {
      document.exitFullscreen();
    }
  }

  function handleVolume(event: Event) {
    audio.setVolume(Number((event.target as HTMLInputElement).value));
  }

  function handleMute() {
    audio.setMute(!audio.mute);
  }

  async function handleSetFrequency(value?: number) {
    if (!radio.connected) return;

    const frequency = value
      ? value
      : await inputModal
          .show('Frequency (KHz)', radio.frequency !== undefined ? Math.floor(radio.frequency / 1e3).toString() : undefined)
          .then((v) => (v ? Number(v) * 1e3 : null));
    if (frequency === null) return;

    try {
      await radio.tune(frequency);
      audio.reset();
    } catch (err) {
      errorModal.show(`Error tuning to ${frequency}:`, `${(err as Error).message}`);
    }
  }

  async function handleSetAudioBandwidth(value: number | string) {
    bandwidthDropdownOpen = false;
    const bandwidth =
      typeof value === 'number'
        ? value
        : await inputModal
            .show('Custom Bandwidth (KHz)', typeof radio.audioBandwidth === 'number' ? (radio.audioBandwidth / 1e3).toString() : undefined)
            .then((v) => (v ? Number(v) * 1e3 : null));
    if (bandwidth === null) return;

    try {
      await radio.setAudioBandwidth(bandwidth);
    } catch (err) {
      errorModal.show(`Error setting audio bandwidth to ${bandwidth}:`, `${(err as Error).message}`);
    }
  }

  async function handleSetAudioAgcMode(value: string) {
    agcModeDropdownOpen = false;
    const mode =
      value === 'custom'
        ? await inputModal
            .show('Custom AGC Time Constant (sec)', typeof radio.audioAgcMode === 'number' ? radio.audioAgcMode.toString() : undefined)
            .then((v) => (v ? Number(v) : null))
        : value;
    if (mode === null) return;

    try {
      await radio.setAudioAgcMode(mode);
    } catch (err) {
      errorModal.show(`Error setting AGC mode to ${mode}:`, `${(err as Error).message}`);
    }
  }

  async function handleScan() {
    const sweeps = (Object.keys(SCAN_BANDS) as (keyof typeof SCAN_BANDS)[])
      .filter((band) => configuration.scan.bands[band])
      .reduce((acc, band) => acc.concat(SCAN_BANDS[band].sweeps), [] as FrequencySweep[]);

    try {
      await radio.scan(sweeps);
    } catch (err) {
      errorModal.show(`Error starting scan:`, `${(err as Error).message}`);
    }
  }

  async function handleAbortScan() {
    try {
      await radio.abortScan();
    } catch (err) {
      errorModal.show(`Error aborting scan:`, `${(err as Error).message}`);
    }
  }

  async function handleScanOptions() {
    const scanOptions = await scanOptionsModal.show($state.snapshot(configuration.scan));
    if (scanOptions === null) return;
    configuration.scan = scanOptions;
    configuration.save();
  }

  function handleAddBookmark() {
    const frequency = radio.frequency;
    if (frequency && !configuration.hasBookmark(frequency)) {
      configuration.bookmarks.push({ frequency, label: '' });
      configuration.save();
    }
  }

  async function handleEditBookmark() {
    if (bookmarkSelectedIndex === undefined) return;
    const bookmark = await editBookmarkModal.show($state.snapshot(configuration.bookmarks[bookmarkSelectedIndex]));
    if (bookmark === null) {
      return;
    } else if (bookmark === undefined) {
      configuration.bookmarks.splice(bookmarkSelectedIndex, 1);
    } else {
      configuration.bookmarks[bookmarkSelectedIndex] = bookmark;
    }
    configuration.save();
  }

  $effect(() => {
    if (!radio.connected) return;

    if (radio.scanning) {
      audio.stop();
    } else {
      audio.start();
    }
  });

  $effect(() => {
    setInterval(() => {
      currentTime = new Date();
    }, 1000);
  });
</script>

<main class="text-gray-800 dark:text-gray-200">
  <div class="container mx-auto h-svh rounded-2xl bg-gray-50 p-4 lg:mt-8 lg:h-[60svh] dark:bg-gray-600">
    <div class="mx-auto mb-4 grid grid-cols-3 items-center">
      <div><Toggle on:click={handleConnect} checked={radio.connected} size="large" color="primary">Connect</Toggle></div>
      <div class="text-center">{formatTime(currentTime)}</div>
      <div class="flex justify-end">
        <button
          class="rounded-lg p-2.5 text-gray-500 hover:bg-gray-100 focus:outline-hidden dark:text-gray-400 dark:hover:bg-gray-700"
          onclick={handleToggleFullscreen}
          aria-label="fullscreen"
        >
          <span class="icon-[bx--fullscreen] block text-xl"></span>
        </button>
        <DarkMode />
      </div>
    </div>
    <div class="grid w-full grid-cols-7">
      <div class="col-span-4 mx-4 my-auto">
        <div class="grid grid-flow-row gap-4">
          <div class="mb-2">
            <button class="cursor-pointer text-5xl" disabled={!radio.connected} onclick={() => handleSetFrequency()}>{formatFrequency(radio.frequency)}</button>
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <Label>Power</Label>
              <div class="ml-2">
                {formatPower(radio.power)}
              </div>
            </div>
            <div>
              <Label>Buffer</Label>
              <div class="ml-2">
                {formatBufferLevel(audio.bufferLevel)}
              </div>
            </div>
          </div>
          <div class="grid grid-cols-2 gap-2">
            <div>
              <Label>Bandwidth</Label>
              <ButtonGroup>
                <div class="mx-2 my-auto">{formatBandwidth(radio.audioBandwidth)}</div>
                <Button class="px-2 py-1 text-xs" disabled={!radio.connected}><span class="icon-[bx--caret-down] block text-xl"></span></Button>
                <Dropdown bind:open={bandwidthDropdownOpen}>
                  {#each AUDIO_BANDWIDTHS as value (value)}
                    <DropdownItem on:click={() => handleSetAudioBandwidth(value)}>{value / 1e3} KHz</DropdownItem>
                  {/each}
                  <DropdownItem on:click={() => handleSetAudioBandwidth('custom')}>Custom</DropdownItem>
                </Dropdown>
              </ButtonGroup>
            </div>
            <div>
              <Label>AGC</Label>
              <ButtonGroup>
                <div class="mx-2 my-auto">{formatAgcMode(radio.audioAgcMode)}</div>
                <Button class="px-2 py-1 text-xs" disabled={!radio.connected}><span class="icon-[bx--caret-down] block text-xl"></span></Button>
                <Dropdown bind:open={agcModeDropdownOpen}>
                  {#each AUDIO_AGC_PRESETS as value (value)}
                    <DropdownItem on:click={() => handleSetAudioAgcMode(value)}>{value}</DropdownItem>
                  {/each}
                  <DropdownItem on:click={() => handleSetAudioAgcMode('custom')}>Custom</DropdownItem>
                </Dropdown>
              </ButtonGroup>
            </div>
          </div>
          <div>
            <Label>Volume</Label>
            <div class="flex items-center gap-2">
              <Range size="lg" on:change={handleVolume} value={audio.volume} />
              <button
                class="text-primary-600 dark:text-primary-500 rounded-lg p-2 shadow-sm hover:bg-gray-100 focus:outline-hidden dark:hover:bg-gray-700"
                onclick={handleMute}
                aria-label="mute"
              >
                {#if audio.mute}
                  <span class="icon-[bxs--volume-mute] block text-xl"></span>
                {:else}
                  <span class="icon-[bxs--volume-full] block text-xl"></span>
                {/if}
              </button>
            </div>
          </div>
        </div>
      </div>
      <div class="col-span-3">
        <Tabs defaultClass="flex justify-end" contentClass="mt-0" tabStyle="full">
          <TabItem class="w-full" defaultClass="!p-3 focus:!ring-0 group-first:!rounded-tl-lg group-first:!rounded-s-none" title="Channels" open>
            <div class="grid grid-flow-row gap-2">
              <div class="h-[calc(100svh-194px)] overflow-auto rounded-b-lg bg-white lg:h-[calc(60svh-194px)] dark:bg-gray-800">
                <Table hoverable={true}>
                  <TableHead class="bg-gray-100 dark:bg-gray-700">
                    <TableHeadCell
                      class="cursor-pointer"
                      padding="pl-4 py-2"
                      onclick={() => {
                        scanResultsSortFn = (a, b) => a.frequency - b.frequency;
                      }}>Frequency</TableHeadCell
                    >
                    <TableHeadCell
                      class="cursor-pointer"
                      padding="py-2 text-center"
                      onclick={() => {
                        scanResultsSortFn = (a, b) => b.power - a.power;
                      }}>Power</TableHeadCell
                    >
                    <TableHeadCell padding="py-2"></TableHeadCell>
                    <TableHeadCell padding="py-2"></TableHeadCell>
                  </TableHead>
                  <TableBody tableBodyClass="text-lg">
                    {#each Object.values(radio.scanResults)
                      .sort(scanResultsSortFn)
                      .filter((r) => r.power > configuration.scan.threshold) as result (result)}
                      <TableBodyRow
                        class="select-none hover:bg-blue-100 dark:hover:bg-blue-400 opacity-{formatScanOpacity(result.timestamp)}"
                        on:dblclick={() => handleSetFrequency(result.frequency)}
                      >
                        <TableBodyCell tdClass="pl-4 py-1.5">{formatFrequency(result.frequency)}</TableBodyCell>
                        <TableBodyCell tdClass="p-1.5 text-center">{formatPower(result.power)}</TableBodyCell>
                        <TableBodyCell tdClass="p-1.5"
                          ><span class="icon-[bx--signal-{formatSignalStrength(result.power)}] block text-2xl"></span></TableBodyCell
                        >
                        <TableBodyCell tdClass="p-1.5">
                          <div class="text-2xl font-bold text-orange-300">
                            <span class="block {configuration.hasBookmark(result.frequency) ? 'icon-[bxs--star]' : 'icon-[bx--star]'}"></span>
                          </div>
                        </TableBodyCell>
                      </TableBodyRow>
                    {/each}
                  </TableBody>
                </Table>
              </div>
              <div class="mt-2 grid grid-flow-col gap-2">
                {#if !radio.scanning}
                  <Button disabled={!radio.connected} on:click={handleScan}>Scan</Button>
                {:else}
                  <Button disabled={!radio.connected} on:click={handleAbortScan}>Abort</Button>
                {/if}
                <Button on:click={handleScanOptions}>Options</Button>
              </div>
            </div>
          </TabItem>
          <TabItem class="w-full" defaultClass="!p-3 focus:!ring-0 group-last:!rounded-tr-lg group-last:!rounded-e-none" title="Bookmarks">
            <div class="grid grid-flow-row gap-2">
              <div class="h-[calc(100svh-194px)] overflow-auto rounded-b-lg bg-white lg:h-[calc(60svh-194px)] dark:bg-gray-800">
                <Table>
                  <TableHead class="bg-gray-100 dark:bg-gray-700">
                    <TableHeadCell padding="pl-4 py-2">Frequency</TableHeadCell>
                    <TableHeadCell padding="pl-1.5 py-2">Label</TableHeadCell>
                  </TableHead>
                  <TableBody tableBodyClass="text-lg">
                    {#each configuration.bookmarks as bookmark, i (bookmark)}
                      <TableBodyRow
                        class="select-none {bookmarkSelectedIndex === i ? 'bg-gray-100 dark:bg-gray-700' : 'hover:bg-blue-100 dark:hover:bg-blue-400'}"
                        on:click={() => {
                          bookmarkSelectedIndex = i;
                        }}
                        on:dblclick={() => handleSetFrequency(bookmark.frequency)}
                      >
                        <TableBodyCell tdClass="pl-4 py-1.5">{formatFrequency(bookmark.frequency)}</TableBodyCell>
                        <TableBodyCell tdClass="p-1.5">{bookmark.label}</TableBodyCell>
                      </TableBodyRow>
                    {/each}
                  </TableBody>
                </Table>
              </div>
              <div class="mt-2 grid grid-flow-col gap-2">
                <Button disabled={!radio.connected} on:click={() => handleAddBookmark()}>Add</Button>
                <Button disabled={bookmarkSelectedIndex === undefined} on:click={() => handleEditBookmark()}>Edit</Button>
              </div>
            </div>
          </TabItem>
        </Tabs>
      </div>
    </div>
  </div>
  <div class="my-3 text-center"><A href="https://github.com/vsergeev/radfly" target="_blank">radfly</A> - v0.3.0</div>
  <ErrorModal bind:this={errorModal} />
  <InputModal bind:this={inputModal} />
  <ScanOptionsModal bind:this={scanOptionsModal} />
  <EditBookmarkModal bind:this={editBookmarkModal} />
</main>
