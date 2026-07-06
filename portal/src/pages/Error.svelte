<script lang="ts">
  import type { PageProps } from "../types";

  let { hotspot, error }: PageProps = $props();
</script>

<main>
  <div class="error">{error || "Something went wrong."}</div>
  <p><a href={hotspot.linkLogin}>Try again</a></p>
</main>
