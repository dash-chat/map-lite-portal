<script lang="ts">
  import type { PageProps } from "../types";

  let { hotspot, error }: PageProps = $props();

  // RouterOS's passwordless "trial" login: hitting link-login-only with a
  // T-<mac> username grants the session, no password involved.
  const connectUrl = $derived(
    `${hotspot.linkLoginOnly}?dst=${hotspot.linkOrigEsc}&username=T-${hotspot.macEsc}`,
  );
</script>

<main class="card">
  <h1>Welcome</h1>
  <p>You are connected to <strong>{hotspot.identity}</strong>. Tap the button below to get started.</p>
  {#if error}
    <div class="error">{error}</div>
  {/if}
  <a class="button" href={connectUrl}>Connect</a>
</main>
