<script lang="ts">
  import { Modal, Button, Input } from 'flowbite-svelte';

  let _title: string | undefined = $state(undefined);
  let _value: string | undefined = $state(undefined);
  let _open: boolean = $state(false);
  let _resolve: (resolve: string | null) => void | undefined;

  export function show(title: string, initial: string | undefined): Promise<string | null> {
    _title = title;
    _value = initial;
    _open = true;

    return new Promise((resolve) => {
      _resolve = resolve;
    });
  }

  function handleSubmit() {
    if (_resolve) _resolve(_value ?? null);
  }

  function handleCancel() {
    if (_resolve) _resolve(null);
  }
</script>

<Modal size="xs" title={_title} classFooter="justify-end" bind:open={_open} on:close={handleCancel} autoclose>
  <form id="form-input">
    <Input bind:value={_value} />
  </form>
  <svelte:fragment slot="footer">
    <Button type="submit" form="form-input" disabled={_value === undefined || _value === ''} on:click={handleSubmit}>Submit</Button>
    <Button on:click={handleCancel}>Cancel</Button>
  </svelte:fragment>
</Modal>
