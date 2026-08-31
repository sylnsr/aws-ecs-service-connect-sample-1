<script setup>
import { onMounted } from 'vue'
import { RouterLink, RouterView, useRouter } from 'vue-router'

import { useSession } from './stores/session'

const session = useSession()
const router = useRouter()

onMounted(() => session.loadPool())

function signOut() {
  session.signOut()
  router.push({ name: 'landing' })
}
</script>

<template>
  <header>
    <nav>
      <RouterLink to="/">ACME Water Utility</RouterLink>
      <template v-if="session.signedIn">
        <RouterLink to="/accounts">Accounts</RouterLink>
        <RouterLink to="/payment-methods">Payment methods</RouterLink>
      </template>
      <span class="spacer" />
      <!--
        Which pool served this page. Cosmetic for a customer, but it is the only
        way to watch a blue/green listener swap from a browser -- both pools
        serve identical customer responses by design.
      -->
      <span v-if="session.pool" class="pool" :data-pool="session.pool.pool">
        {{ session.pool.pool }} / {{ session.pool.role }} / {{ session.pool.store }}
      </span>
      <button v-if="session.signedIn" type="button" @click="signOut">Sign out</button>
    </nav>
  </header>

  <main>
    <RouterView />
  </main>
</template>
