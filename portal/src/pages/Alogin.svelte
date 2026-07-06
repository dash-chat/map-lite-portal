<script lang="ts">
  import type { PageProps } from "../types";

  let { hotspot }: PageProps = $props();
</script>

<main>
  <p>You are now connected. <a href={hotspot.linkRedirect}>Continue</a></p>
</main>
