<script lang="ts">
  import type { ScanOptions } from './RadioInterface.svelte';
  import { SCAN_BANDS } from './RadioInterface.svelte';
  import { Configuration } from './Configuration.svelte';

  import { Modal, Label, Checkbox, Input, Button } from 'flowbite-svelte';

  let _scanOptions: ScanOptions = $state(Configuration.DEFAULT_CONFIGURATION.scan);
  let _open: boolean = $state(false);
  let _resolve: (resolve: ScanOptions | null) => void | undefined;

  export function show(scanOptions: ScanOptions): Promise<ScanOptions | null> {
    _scanOptions = scanOptions;
    _open = true;

    return new Promise((resolve) => {
      _resolve = resolve;
    });
  }

  function handleDefaults() {
    _scanOptions = Configuration.DEFAULT_CONFIGURATION.scan;
  }

  function handleAllBandsCheckbox(value: boolean) {
    Object.keys(_scanOptions.bands).map((b: string) => {
      _scanOptions.bands[b] = value;
    });
  }

  function handleSave() {
    _open = false;
    if (_resolve) _resolve(_scanOptions);
  }

  function handleCancel() {
    _open = false;
    if (_resolve) _resolve(null);
  }
</script>

<Modal size="xs" title="Scan Options" classFooter="justify-end" bind:open={_open} on:close={handleCancel}>
  {#if _scanOptions}
    <div>
      <Label class="mb-2 font-bold">Bands</Label>
      <Checkbox
        bind:checked={() => Object.values(_scanOptions.bands).every((x) => x), handleAllBandsCheckbox}
        indeterminate={!Object.values(_scanOptions.bands).every((x, _, values) => x === values[0])}
        class="text-md">All Bands</Checkbox
      >
      {#each Object.keys(SCAN_BANDS) as (keyof typeof SCAN_BANDS)[] as band (band)}
        <Checkbox class="text-md" bind:checked={_scanOptions.bands[band]}>{SCAN_BANDS[band].description}</Checkbox>
      {/each}
    </div>
    <div>
      <Label class="mb-2 font-bold">Threshold (dbFS)</Label>
      <Input type="number" id="threshold" bind:value={_scanOptions.threshold} />
    </div>
  {/if}
  <svelte:fragment slot="footer">
    <Button class="mr-auto" on:click={handleDefaults}>Defaults</Button>
    <Button on:click={handleSave}>Save</Button>
    <Button on:click={handleCancel}>Cancel</Button>
  </svelte:fragment>
</Modal>
