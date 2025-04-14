<script lang="ts">
  import { Modal, Alert, Button } from 'flowbite-svelte';

  let _message: string | undefined = $state(undefined);
  let _title: string | undefined = $state(undefined);
  let _open: boolean = $state(false);

  export function show(title: string, message?: string) {
    _message = message;
    _title = title;
    _open = true;
  }
</script>

<Modal size="sm" title="Error" classFooter="justify-end" bind:open={_open} autoclose outsideclose>
  <Alert color="red" class="text-lg">
    <span slot="icon"><span class="icon-[bx--error-circle] block text-2xl"></span></span>
    <span class="font-bold">{_title}</span>
    <p>
      {_message}
    </p>
  </Alert>
  <svelte:fragment slot="footer">
    <Button>Close</Button>
  </svelte:fragment>
</Modal>
