<script lang="ts">
  import type { Component } from "svelte";
  import type { HotspotPage, PageProps } from "./types";
  import Login from "./pages/Login.svelte";
  import Alogin from "./pages/Alogin.svelte";
  import Status from "./pages/Status.svelte";
  import Logout from "./pages/Logout.svelte";
  import ErrorPage from "./pages/Error.svelte";

  let { hotspot, error }: PageProps = $props();

  const pages: Record<HotspotPage, Component<PageProps>> = {
    login: Login,
    alogin: Alogin,
    status: Status,
    logout: Logout,
    error: ErrorPage,
  };
  const Page = $derived(pages[hotspot.page] ?? Login);
</script>

<Page {hotspot} {error} />
