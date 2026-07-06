<script lang="ts">
  import type { PageProps } from "../types";

  let { hotspot }: PageProps = $props();
</script>

<main>
  <p>You have been logged out. <a href={hotspot.linkLogin}>Connect again</a></p>
</main>
