<script lang="ts">
  import type { Bookmark } from './RadioInterface.svelte';

  import { Modal, Label, Input, Button } from 'flowbite-svelte';

  let _bookmark: Bookmark | undefined = $state(undefined);
  let _open: boolean = $state(false);
  let _resolve: (resolve: Bookmark | null | undefined) => void | undefined;

  export function show(bookmark: Bookmark): Promise<Bookmark | null | undefined> {
    _bookmark = bookmark;
    _open = true;

    return new Promise((resolve) => {
      _resolve = resolve;
    });
  }

  function handleDelete() {
    _open = false;
    if (_resolve) _resolve(undefined);
  }

  function handleSave() {
    _open = false;
    if (_resolve) _resolve(_bookmark);
  }

  function handleCancel() {
    _open = false;
    if (_resolve) _resolve(null);
  }
</script>

<Modal size="xs" title="Edit Bookmark" classFooter="justify-end" bind:open={_open} on:close={handleCancel}>
  {#if _bookmark}
    <div>
      <Label class="mb-2 font-bold">Frequency</Label>
      <p>{Math.floor(_bookmark.frequency / 1e3)} KHz</p>
    </div>
    <div>
      <Label class="mb-2 font-bold">Label</Label>
      <Input id="label" bind:value={_bookmark.label} />
    </div>
  {/if}
  <svelte:fragment slot="footer">
    <Button class="mr-auto" on:click={handleDelete}>Delete</Button>
    <Button on:click={handleSave}>Save</Button>
    <Button on:click={handleCancel}>Cancel</Button>
  </svelte:fragment>
</Modal>
