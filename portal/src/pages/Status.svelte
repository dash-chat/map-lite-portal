<script lang="ts">
  import type { PageProps } from "../types";

  let { hotspot }: PageProps = $props();
</script>

<main class="card">
  <h1>You are connected</h1>
  <dl>
    <dt>IP address</dt><dd>{hotspot.ip}</dd>
    <dt>Connected for</dt><dd>{hotspot.uptime}</dd>
    <dt>Downloaded</dt><dd>{hotspot.bytesOutNice}</dd>
    <dt>Uploaded</dt><dd>{hotspot.bytesInNice}</dd>
  </dl>
  <a href={hotspot.linkLogout}>Log out</a>
</main>
